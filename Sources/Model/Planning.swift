import Foundation

// MARK: - Errors

/// Every way a conversion can fail, each with a plain-language message and a way forward.
enum ConversionError: Error, Equatable {
    case drmProtected
    case unreadable(String)
    case noVideoTrack
    case noAudioTrack
    case needsAdvancedEngine
    case unsupportedCombination(String)
    case diskFull
    case cancelled
    case outputTooLarge
    case engineFailed(String)

    var title: String {
        switch self {
        case .drmProtected: return "This file is protected"
        case .unreadable: return "Can't open this file"
        case .noVideoTrack: return "No video in this file"
        case .noAudioTrack: return "No sound in this file"
        case .needsAdvancedEngine: return "This format needs the full engine"
        case .unsupportedCombination: return "That combination isn't possible"
        case .diskFull: return "Not enough free space"
        case .cancelled: return "Cancelled"
        case .outputTooLarge: return "The result would be too large"
        case .engineFailed: return "The conversion didn't finish"
        }
    }

    var message: String {
        switch self {
        case .drmProtected:
            return "Movies and shows from Apple TV, Netflix and similar services use copy protection (DRM). No app can convert them. Files you recorded or own without DRM work fine."
        case .unreadable(let detail):
            let tail = detail.isEmpty ? "" : " (\(detail))"
            return "The file may be damaged, still downloading, locked with a password or in a format Fluxa can't read\(tail). Try opening it in Files first."
        case .noVideoTrack:
            return "This file has only sound. Choose an audio format such as MP3 or M4A instead."
        case .noAudioTrack:
            return "This video has no audio track, so there is nothing to extract."
        case .needsAdvancedEngine:
            return "Fluxa needs its extended converter for this pair of formats, and it isn't available in this build. Choose MP4, MOV, M4V, 3GP, M4A, WAV, AIFF, CAF or GIF."
        case .unsupportedCombination(let detail):
            return detail
        case .diskFull:
            return "Free up some storage on this device and try again. Converted files are stored temporarily until you save or share them."
        case .cancelled:
            return "Nothing was saved."
        case .outputTooLarge:
            return "The converted file would be bigger than this device can hold. Choose a lower quality or a smaller size."
        case .engineFailed(let detail):
            return detail.isEmpty ? "Something went wrong. Try again, or pick a different format." : "Something went wrong: \(detail). Try again, or pick a different format."
        }
    }
}

// MARK: - Plan

enum EngineKind: String, Equatable, Codable {
    case native
    case ffmpeg

    var title: String { self == .native ? "Apple hardware" : "Extended engine" }
}

enum PlanKind: String, Equatable {
    /// Both streams are copied into the new container: seconds, no quality loss.
    case remux
    /// At least one stream is re-encoded.
    case transcode
    /// Video in, audio file out.
    case extractAudio
    /// Video in, GIF / WebP / APNG out.
    case animatedImage
    /// Audio file in, audio file out.
    case audioConvert
}

struct ConversionPlan: Equatable {
    var kind: PlanKind
    var engine: EngineKind
    /// The engine to try when the first one can't open the file.
    var fallback: EngineKind?
    var copyVideo: Bool
    var copyAudio: Bool
    var videoCodec: VideoCodec?
    var audioCodec: AudioCodec?
    var notes: [String] = []

    /// A short label for the queue row.
    var badge: String {
        switch kind {
        case .remux: return "Lossless · fast"
        case .extractAudio: return "Audio only"
        case .animatedImage: return "Animated image"
        case .audioConvert: return "Audio"
        case .transcode:
            if copyVideo { return "Video untouched" }
            if engine == .native { return "Hardware" }
            return "Converted"
        }
    }
}

// MARK: - The matrix

/// Decides how a source file becomes a target format: copy the streams, use Apple's hardware encoder, or use FFmpeg.
/// Pure logic, no file access, so every pair can be unit tested.
enum FormatMatrix {
    /// Video codecs Apple's writer can pass through into each container without re-encoding.
    static func nativeCanCopyVideo(_ codec: VideoCodec, into format: OutputFormat) -> Bool {
        switch format {
        case .mp4, .m4v: return codec == .h264 || codec == .hevc
        case .mov: return [.h264, .hevc, .prores, .mjpeg, .mpeg4].contains(codec)
        case .threeGP: return codec == .h264
        default: return false
        }
    }

    static func nativeCanCopyAudio(_ codec: AudioCodec, into format: OutputFormat) -> Bool {
        switch format {
        case .mp4, .m4v, .threeGP: return codec == .aac
        case .mov: return codec == .aac || codec == .alac || codec == .pcm
        case .m4a: return codec == .aac || codec == .alac
        case .wav, .aiff, .caf: return codec == .pcm
        default: return false
        }
    }

    static func nativeCanEncodeVideo(_ codec: VideoCodec, into format: OutputFormat) -> Bool {
        guard codec == .h264 || codec == .hevc else { return false }
        switch format {
        case .mp4, .m4v, .mov: return true
        case .threeGP: return codec == .h264
        default: return false
        }
    }

    static func nativeCanEncodeAudio(_ codec: AudioCodec, into format: OutputFormat) -> Bool {
        switch format {
        case .mp4, .m4v, .threeGP: return codec == .aac
        case .mov: return codec == .aac || codec == .alac || codec == .pcm
        case .m4a: return codec == .aac || codec == .alac
        case .wav, .aiff, .caf: return codec == .pcm
        default: return false
        }
    }

    /// Plans one conversion. Throws a `ConversionError` when the pair is impossible.
    static func plan(probe: MediaProbe, spec: OutputSpec, ffmpegAvailable: Bool) throws -> ConversionPlan {
        if probe.isProtected { throw ConversionError.drmProtected }
        let format = spec.format

        func choose(nativeOK: Bool, notes: [String] = []) throws -> (EngineKind, EngineKind?) {
            if nativeOK && probe.nativeReadable {
                return (.native, ffmpegAvailable ? .ffmpeg : nil)
            }
            if ffmpegAvailable { return (.ffmpeg, nil) }
            throw ConversionError.needsAdvancedEngine
        }

        switch format.category {
        case .audio:
            guard probe.hasAudio else { throw ConversionError.noAudioTrack }
            let target = spec.resolvedAudioCodec ?? .aac
            let source = probe.primaryAudio?.codec
            let sameCodec = source == target
            let copy = sameCodec && !spec.altersSound && !spec.mute && format.audioCodecs.contains(target)
                && (spec.audioCodec == nil || spec.audioCodec == source)
            let nativeOK: Bool
            if copy { nativeOK = nativeCanCopyAudio(target, into: format) && format.engineSupport == .nativeOrFFmpeg }
            else { nativeOK = nativeCanEncodeAudio(target, into: format) && format.engineSupport == .nativeOrFFmpeg }
            let (engine, fallback) = try choose(nativeOK: nativeOK)
            return ConversionPlan(
                kind: probe.hasVideo ? .extractAudio : .audioConvert,
                engine: engine, fallback: fallback,
                copyVideo: false, copyAudio: copy,
                videoCodec: nil, audioCodec: target,
                notes: probe.hasVideo ? ["Uses the first audio track."] : []
            )

        case .image:
            guard probe.hasVideo else { throw ConversionError.noVideoTrack }
            // GIF prefers the extended engine (optimised palette); Apple's ImageIO is the fallback.
            let nativeOK = format == .apng || (format == .gif && !ffmpegAvailable)
            let (engine, fallback) = try choose(nativeOK: nativeOK)
            var notes = ["Animated images have no sound."]
            if probe.duration > 30 { notes.append("Long clips make very large images. Consider trimming to 30 seconds or less.") }
            return ConversionPlan(
                kind: .animatedImage, engine: engine, fallback: fallback,
                copyVideo: false, copyAudio: false, videoCodec: nil, audioCodec: nil, notes: notes
            )

        case .video:
            guard let video = probe.video else { throw ConversionError.noVideoTrack }
            let targetVideo = spec.resolvedVideoCodec ?? .h264
            let sourceVideo = video.codec
            let copyVideo = sourceVideo != nil
                && format.videoCodecs.contains(sourceVideo!)
                && (spec.videoCodec == nil || spec.videoCodec == sourceVideo)
                && !spec.altersPicture

            var copyAudio = false
            var targetAudio: AudioCodec? = nil
            if probe.hasAudio && !spec.mute {
                targetAudio = spec.resolvedAudioCodec
                let source = probe.primaryAudio?.codec
                copyAudio = source != nil && source == targetAudio
                    && format.audioCodecs.contains(source!)
                    && !spec.altersSound
                    && (spec.audioCodec == nil || spec.audioCodec == source)
            }

            var nativeOK = format.engineSupport == .nativeOrFFmpeg
            if nativeOK {
                if copyVideo { nativeOK = nativeCanCopyVideo(sourceVideo!, into: format) }
                else { nativeOK = nativeCanEncodeVideo(targetVideo, into: format) }
            }
            if nativeOK, let targetAudio {
                if copyAudio { nativeOK = nativeCanCopyAudio(targetAudio, into: format) }
                else { nativeOK = nativeCanEncodeAudio(targetAudio, into: format) }
            }

            let (engine, fallback) = try choose(nativeOK: nativeOK)
            var notes: [String] = []
            if video.isHDR && spec.tonemapHDR && !copyVideo && targetVideo != .hevc {
                notes.append("HDR colour is converted to standard colour.")
            }
            if probe.audio.count > 1 { notes.append("Keeps the first audio track.") }
            if probe.subtitleCount > 0 {
                notes.append("Subtitles are not kept in this version.")
            }
            return ConversionPlan(
                kind: copyVideo && (copyAudio || targetAudio == nil) ? .remux : .transcode,
                engine: engine, fallback: fallback,
                copyVideo: copyVideo, copyAudio: copyAudio,
                videoCodec: copyVideo ? sourceVideo : targetVideo,
                audioCodec: targetAudio,
                notes: notes
            )
        }
    }

    /// For the Formats guide and tests: how a given source codec pair reaches every output, ignoring the file itself.
    /// Formats missing from the result are impossible for this source.
    static func summary(for probe: MediaProbe, ffmpegAvailable: Bool = true) -> [OutputFormat: ConversionPlan] {
        var result: [OutputFormat: ConversionPlan] = [:]
        for format in OutputFormat.allCases {
            var spec = OutputSpec()
            spec.format = format
            if let planned = try? FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: ffmpegAvailable) {
                result[format] = planned
            }
        }
        return result
    }
}
