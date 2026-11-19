import Foundation

/// What the linked FFmpeg build can do beyond the basics. Filled in by the engine from the real library.
struct FFmpegCapabilities: Equatable {
    /// libzimg is present, so HDR to SDR tone mapping works.
    var hasZscale: Bool = false
    /// Encoders found in the build. Empty means "assume the standard Fluxa build".
    var encoders: Set<String> = []

    func has(_ encoder: String) -> Bool { encoders.isEmpty || encoders.contains(encoder) }
}

/// Builds the FFmpeg argument list for a job. Pure, so the exact command for every output format is unit tested.
enum FFmpegCommandBuilder {
    static func muxer(for format: OutputFormat) -> String {
        switch format {
        case .mp4: return "mp4"
        case .mov: return "mov"
        case .m4v: return "ipod"
        case .threeGP: return "3gp"
        case .mkv: return "matroska"
        case .webm: return "webm"
        case .avi: return "avi"
        case .flv: return "flv"
        case .wmv: return "asf"
        case .mpg: return "mpeg"
        case .ts: return "mpegts"
        case .ogv: return "ogg"
        case .m4a: return "ipod"
        case .mp3: return "mp3"
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .caf: return "caf"
        case .flac: return "flac"
        case .ogg: return "ogg"
        case .opus: return "opus"
        case .ac3: return "ac3"
        case .gif: return "gif"
        case .webp: return "webp"
        case .apng: return "apng"
        }
    }

    /// MPEG-1/2 only allows a fixed list of frame rates.
    static func snappedMPEGFrameRate(_ fps: Double) -> String {
        let table: [(Double, String)] = [(23.976, "24000/1001"), (24, "24"), (25, "25"), (29.97, "30000/1001"), (30, "30"), (50, "50"), (59.94, "60000/1001"), (60, "60")]
        return table.min(by: { abs($0.0 - fps) < abs($1.0 - fps) })?.1 ?? "30000/1001"
    }

    static func arguments(job: TranscodeJob, capabilities: FFmpegCapabilities = FFmpegCapabilities()) -> [String] {
        let spec = job.spec
        let plan = job.plan
        let probe = job.probe
        var args: [String] = ["-hide_banner", "-nostdin", "-y"]

        // Trim goes before the input so seeking is fast.
        var duration = probe.duration
        if let trim = spec.trim {
            let start = max(0, trim.lowerBound)
            args += ["-ss", seconds(start)]
            duration = max(0.1, min(trim.upperBound, probe.duration) - start)
        }
        args += ["-i", job.source.path]
        if spec.trim != nil { args += ["-t", seconds(duration)] }

        args += ["-sn", "-dn"]
        if spec.stripMetadata {
            args += ["-map_metadata", "-1", "-map_chapters", "-1"]
        } else {
            args += ["-map_metadata", "0"]
        }

        switch spec.format.category {
        case .audio:
            args += ["-vn", "-map", "0:a:0"]
            args += audioArguments(spec: spec, plan: plan, probe: probe)
        case .image:
            args += ["-an", "-map", "0:v:0"]
            args += imageArguments(spec: spec, probe: probe, duration: duration)
        case .video:
            args += ["-map", "0:v:0"]
            if probe.hasAudio && !spec.mute { args += ["-map", "0:a:0"] } else { args += ["-an"] }
            args += videoArguments(spec: spec, plan: plan, probe: probe, capabilities: capabilities)
            if probe.hasAudio && !spec.mute { args += audioArguments(spec: spec, plan: plan, probe: probe) }
            if [.mp4, .mov, .m4v, .threeGP].contains(spec.format) { args += ["-movflags", "+faststart"] }
        }

        args += ["-f", muxer(for: spec.format), job.output.path]
        return args
    }

    // MARK: Video

    static func outputSize(spec: OutputSpec, probe: MediaProbe) -> (width: Int, height: Int)? {
        guard let video = probe.video else { return nil }
        var size = video.displaySize
        if spec.rotation == .cw90 || spec.rotation == .ccw90 { size = (size.height, size.width) }
        return BitrateEstimator.outputSize(sourceWidth: size.width, sourceHeight: size.height, resolution: spec.resolution)
    }

    static func videoArguments(spec: OutputSpec, plan: ConversionPlan, probe: MediaProbe, capabilities: FFmpegCapabilities) -> [String] {
        guard let video = probe.video else { return [] }
        if plan.copyVideo {
            var copy = ["-c:v", "copy"]
            if video.codec == .hevc && [.mp4, .mov, .m4v].contains(spec.format) { copy += ["-tag:v", "hvc1"] }
            if video.codec == .h264 && [.mp4, .mov, .m4v].contains(spec.format) { copy += ["-tag:v", "avc1"] }
            return copy
        }
        let codec = plan.videoCodec ?? spec.resolvedVideoCodec ?? .h264
        var args: [String] = ["-c:v", codec.ffmpegEncoder]

        // Filters: rotate, flip, tone map, frame rate, scale, pixel format. The decoder already applies the stored rotation.
        var filters: [String] = []
        switch spec.rotation {
        case .none: break
        case .cw90: filters.append("transpose=1")
        case .cw180: filters.append("transpose=1,transpose=1")
        case .ccw90: filters.append("transpose=2")
        }
        if spec.flipHorizontal { filters.append("hflip") }
        if video.isHDR && spec.tonemapHDR && capabilities.hasZscale {
            filters.append("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv")
        }

        var fps = min(spec.fps ?? video.fps, max(video.fps, 1))
        if codec == .mpeg2 {
            let snapped = snappedMPEGFrameRate(fps)
            filters.append("fps=\(snapped)")
            fps = FFmpegProbeParser.rate(snapped)
        } else if spec.fps != nil && fps < video.fps - 0.01 {
            filters.append("fps=\(trimmed(fps))")
        }

        let out = outputSize(spec: spec, probe: probe) ?? (video.displaySize.width & ~1, video.displaySize.height & ~1)
        let display = video.displaySize
        let rotated = (spec.rotation == .cw90 || spec.rotation == .ccw90) ? (display.height, display.width) : display
        if out.width != rotated.0 || out.height != rotated.1 || out.width % 2 != 0 || out.height % 2 != 0 {
            filters.append("scale=\(out.width):\(out.height):flags=lanczos")
        }

        let pixelFormat: String
        switch codec {
        case .prores: pixelFormat = "yuv422p10le"
        case .mjpeg: pixelFormat = "yuvj420p"
        default: pixelFormat = "yuv420p"
        }
        filters.append("format=\(pixelFormat)")
        args += ["-vf", filters.joined(separator: ",")]

        let kbps = spec.videoBitrateKbps ?? BitrateEstimator.videoKbps(codec: codec, width: out.width, height: out.height, fps: fps, quality: spec.quality)
        switch codec {
        case .h264, .hevc:
            args += ["-b:v", "\(kbps)k", "-maxrate", "\(Int(Double(kbps) * 1.5))k", "-bufsize", "\(kbps * 2)k", "-allow_sw", "1"]
            if codec == .h264 { args += ["-profile:v", "high"] }
            if codec == .hevc && [.mp4, .mov, .m4v].contains(spec.format) { args += ["-tag:v", "hvc1"] }
        case .vp9:
            args += ["-b:v", "\(kbps)k", "-deadline", "good", "-cpu-used", "4", "-row-mt", "1", "-threads", "0"]
        case .vp8:
            args += ["-b:v", "\(kbps)k", "-deadline", "good", "-cpu-used", "4", "-threads", "0"]
        case .mpeg4:
            args += ["-b:v", "\(kbps)k", "-qmin", "2"]
            if spec.format == .avi { args += ["-vtag", "XVID"] }
        case .mpeg2:
            args += ["-b:v", "\(kbps)k", "-maxrate", "\(Int(Double(kbps) * 1.5))k", "-bufsize", "\(min(kbps * 2, 1835))k"]
        case .wmv2, .flv1, .theora, .h263:
            args += ["-b:v", "\(kbps)k"]
        case .mjpeg:
            let q = [8, 5, 3, 2][spec.quality.rawValue]
            args += ["-q:v", "\(q)"]
        case .prores:
            args += ["-profile:v", "2", "-vendor", "apl0"]
        }
        return args
    }

    // MARK: Audio

    static func pcmCodec(for format: OutputFormat) -> String {
        format == .aiff ? "pcm_s16be" : "pcm_s16le"
    }

    static func audioArguments(spec: OutputSpec, plan: ConversionPlan, probe: MediaProbe) -> [String] {
        if plan.copyAudio { return ["-c:a", "copy"] }
        let codec = plan.audioCodec ?? spec.resolvedAudioCodec ?? .aac
        var args: [String]
        if codec == .pcm {
            args = ["-c:a", pcmCodec(for: spec.format)]
        } else {
            args = ["-c:a", codec.ffmpegEncoder]
        }
        if !codec.isLossless {
            let kbps = spec.audioBitrateKbps ?? codec.defaultBitrate
            args += ["-b:a", "\(kbps)k"]
        }
        var rate = spec.audioSampleRate ?? probe.primaryAudio?.sampleRate ?? 44100
        if rate <= 0 { rate = 44100 }
        if codec == .opus { rate = 48000 }
        if codec == .mp3 && rate > 48000 { rate = 48000 }
        if codec == .aac && rate > 96000 { rate = 48000 }
        if codec == .ac3 && ![32000, 44100, 48000].contains(rate) { rate = 48000 }
        args += ["-ar", "\(rate)"]
        let channels = probe.primaryAudio?.channels ?? 2
        if channels > 2 || channels == 0 { args += ["-ac", "2"] }
        if codec == .opus { args += ["-vbr", "on"] }
        return args
    }

    // MARK: Animated images

    static func imageArguments(spec: OutputSpec, probe: MediaProbe, duration: Double) -> [String] {
        let options = spec.gif
        let sourceWidth = probe.video?.displaySize.width ?? options.maxWidth
        let width = max(16, min(options.maxWidth, sourceWidth)) & ~1
        // Keep animated images small: at most 600 frames.
        let fps = max(3, min(options.fps, 600 / max(duration, 1)))
        var chain = "fps=\(trimmed(fps)),scale=\(width):-2:flags=lanczos"
        switch spec.format {
        case .gif:
            let colors = max(8, min(256, options.maxColors))
            let dither = options.dither ? "bayer:bayer_scale=4" : "none"
            chain += ",split[s0][s1];[s0]palettegen=max_colors=\(colors):stats_mode=diff[p];[s1][p]paletteuse=dither=\(dither):diff_mode=rectangle"
            return ["-vf", chain, "-loop", options.loops ? "0" : "-1"]
        case .webp:
            return ["-vf", chain, "-c:v", "libwebp_anim", "-lossless", "0", "-q:v", "70", "-loop", options.loops ? "0" : "1"]
        default:
            return ["-vf", chain + ",format=rgba", "-c:v", "apng", "-plays", options.loops ? "0" : "1"]
        }
    }

    // MARK: Helpers

    private static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.3f", value)
        var result = text
        while result.contains(".") && (result.hasSuffix("0") || result.hasSuffix(".")) { result.removeLast() }
        return result
    }
}
