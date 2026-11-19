import Foundation

/// One-tap recipes shown on the setup screen.
struct ConversionPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let spec: OutputSpec

    static let all: [ConversionPreset] = [
        ConversionPreset(
            id: "universal", title: "Universal MP4", subtitle: "H.264 + AAC. Plays everywhere.", symbol: "play.rectangle.fill",
            spec: OutputSpec(format: .mp4, videoCodec: .h264, audioCodec: .aac, resolution: .hd1080, quality: .high)
        ),
        ConversionPreset(
            id: "fix", title: "Fix \"won't play\"", subtitle: "Re-wrap to a file every device opens.", symbol: "wrench.and.screwdriver.fill",
            spec: OutputSpec(format: .mp4, videoCodec: .h264, audioCodec: .aac, quality: .high)
        ),
        ConversionPreset(
            id: "iphone", title: "iPhone & iPad", subtitle: "HEVC in MP4. Smaller, sharp.", symbol: "iphone",
            spec: OutputSpec(format: .mp4, videoCodec: .hevc, audioCodec: .aac, quality: .high)
        ),
        ConversionPreset(
            id: "android", title: "Android", subtitle: "H.264 720p. Light on storage.", symbol: "smartphone",
            spec: OutputSpec(format: .mp4, videoCodec: .h264, audioCodec: .aac, resolution: .hd720, quality: .balanced)
        ),
        ConversionPreset(
            id: "web", title: "Web (WebM)", subtitle: "VP9 + Opus for browsers.", symbol: "globe",
            spec: OutputSpec(format: .webm, videoCodec: .vp9, audioCodec: .opus, resolution: .hd1080, quality: .balanced)
        ),
        ConversionPreset(
            id: "windows", title: "Windows", subtitle: "WMV for older PCs and Office.", symbol: "pc",
            spec: OutputSpec(format: .wmv, videoCodec: .wmv2, audioCodec: .wmav2, resolution: .hd720, quality: .high)
        ),
        ConversionPreset(
            id: "oldtv", title: "Old TV & DVD player", subtitle: "MPEG-2 with Dolby Digital.", symbol: "tv",
            spec: OutputSpec(format: .mpg, videoCodec: .mpeg2, audioCodec: .ac3, resolution: .sd480, quality: .high)
        ),
        ConversionPreset(
            id: "editing", title: "Editing", subtitle: "ProRes in MOV for Final Cut.", symbol: "film.stack",
            spec: OutputSpec(format: .mov, videoCodec: .prores, audioCodec: .pcm, quality: .maximum)
        ),
        ConversionPreset(
            id: "gif", title: "GIF", subtitle: "Looping, silent, shareable.", symbol: "photo.on.rectangle.angled",
            spec: OutputSpec(format: .gif)
        ),
        ConversionPreset(
            id: "audio", title: "Audio only", subtitle: "MP3 you can play anywhere.", symbol: "waveform",
            spec: OutputSpec(format: .mp3, audioCodec: .mp3, audioBitrateKbps: 192)
        )
    ]

    static func preset(id: String) -> ConversionPreset? { all.first { $0.id == id } }
}

// MARK: - Size and bitrate estimates

enum BitrateEstimator {
    /// Efficiency of each codec relative to H.264 at the same visual quality.
    static func efficiency(_ codec: VideoCodec) -> Double {
        switch codec {
        case .h264: return 1.0
        case .hevc: return 0.65
        case .vp9: return 0.7
        case .vp8: return 1.15
        case .mpeg4: return 1.6
        case .mpeg2: return 2.2
        case .wmv2: return 1.9
        case .flv1: return 2.0
        case .h263: return 2.4
        case .theora: return 1.3
        case .mjpeg: return 6.0
        case .prores: return 14.0
        }
    }

    /// Output size after the resolution cap is applied, keeping the aspect ratio and even numbers.
    static func outputSize(sourceWidth: Int, sourceHeight: Int, resolution: Resolution) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (sourceWidth, sourceHeight) }
        let (displayW, displayH) = (sourceWidth, sourceHeight)
        guard let targetHeight = resolution.height else { return (displayW & ~1, displayH & ~1) }
        // Resolution names refer to the short side, so a vertical 1080x1920 clip stays vertical.
        let short = min(displayW, displayH)
        if targetHeight >= short { return (displayW & ~1, displayH & ~1) }
        let scale = Double(targetHeight) / Double(short)
        let w = Int((Double(displayW) * scale).rounded())
        let h = Int((Double(displayH) * scale).rounded())
        return (max(2, w & ~1), max(2, h & ~1))
    }

    /// Video bitrate in kbit/s for the chosen codec, picture size, frame rate and quality.
    static func videoKbps(codec: VideoCodec, width: Int, height: Int, fps: Double, quality: QualityLevel) -> Int {
        let pixelsPerSecond = Double(max(width, 1) * max(height, 1)) * max(fps, 1)
        var bps = pixelsPerSecond * quality.bitsPerPixel * efficiency(codec)
        if codec == .prores { bps = pixelsPerSecond * 4.2 }   // ProRes 422 is roughly constant per pixel
        if codec == .mjpeg { bps = pixelsPerSecond * 1.6 * (0.6 + 0.2 * Double(quality.rawValue)) }
        return max(100, Int(bps / 1000))
    }

    static func audioKbps(spec: OutputSpec, source: AudioStreamInfo?) -> Int {
        guard let codec = spec.resolvedAudioCodec else { return 0 }
        switch codec {
        case .pcm:
            let rate = spec.audioSampleRate ?? source?.sampleRate ?? 44100
            let channels = max(1, min(source?.channels ?? 2, 2))
            return rate * 16 * channels / 1000
        case .flac: return 700
        case .alac: return 800
        default:
            return spec.audioBitrateKbps ?? codec.defaultBitrate
        }
    }

    /// Expected file size in bytes for a conversion, or nil when it cannot be known (animated images).
    static func estimatedBytes(probe: MediaProbe, spec: OutputSpec, plan: ConversionPlan?) -> Int64? {
        let seconds = effectiveDuration(probe: probe, spec: spec)
        guard seconds > 0 else { return nil }
        switch spec.format.category {
        case .audio:
            let kbps = audioKbps(spec: spec, source: probe.primaryAudio)
            return Int64(Double(kbps) * 1000 / 8 * seconds)
        case .image:
            let width = min(spec.gif.maxWidth, probe.video?.displaySize.width ?? spec.gif.maxWidth)
            let height = Int(Double(width) * Double(probe.video?.displaySize.height ?? 9) / Double(max(probe.video?.displaySize.width ?? 16, 1)))
            let frames = spec.gif.fps * seconds
            let perFrame = Double(width * height) * (spec.format == .gif ? 0.18 : 0.12)
            return Int64(perFrame * frames)
        case .video:
            guard let video = probe.video else { return nil }
            var videoBytes: Double
            if let plan, plan.copyVideo, video.bitrate > 0 {
                videoBytes = Double(video.bitrate) / 8 * seconds
            } else {
                let out = outputSize(sourceWidth: video.displaySize.width, sourceHeight: video.displaySize.height, resolution: spec.resolution)
                let fps = min(spec.fps ?? video.fps, max(video.fps, 1))
                let kbps = spec.videoBitrateKbps ?? videoKbps(codec: spec.resolvedVideoCodec ?? .h264, width: out.width, height: out.height, fps: fps, quality: spec.quality)
                videoBytes = Double(kbps) * 1000 / 8 * seconds
            }
            var audioBytes = 0.0
            if probe.hasAudio && !spec.mute {
                if let plan, plan.copyAudio, let a = probe.primaryAudio, a.bitrate > 0 {
                    audioBytes = Double(a.bitrate) / 8 * seconds
                } else {
                    audioBytes = Double(audioKbps(spec: spec, source: probe.primaryAudio)) * 1000 / 8 * seconds
                }
            }
            return Int64((videoBytes + audioBytes) * 1.02)
        }
    }

    static func effectiveDuration(probe: MediaProbe, spec: OutputSpec) -> Double {
        if let trim = spec.trim { return max(0, min(trim.upperBound, probe.duration) - max(trim.lowerBound, 0)) }
        return probe.duration
    }
}

// MARK: - Naming

enum OutputNamer {
    /// "Holiday.mkv" to "Holiday.mp4", keeping names unique inside `existing`.
    static func fileName(source: String, format: OutputFormat, existing: Set<String> = []) -> String {
        let base = baseName(source)
        var candidate = "\(base).\(format.fileExtension)"
        var n = 2
        while existing.contains(candidate.lowercased()) {
            candidate = "\(base) \(n).\(format.fileExtension)"
            n += 1
        }
        return candidate
    }

    static func baseName(_ source: String) -> String {
        let name = (source as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let cleaned = String(stem.drop(while: { $0 == "." }))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Fluxa" : String(cleaned.prefix(80))
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
