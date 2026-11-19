import Foundation

// MARK: - Probe result

struct VideoStreamInfo: Equatable {
    var codecName: String
    var codec: VideoCodec?
    var width: Int
    var height: Int
    var fps: Double
    var bitrate: Int          // bits per second, 0 when unknown
    var rotation: Int         // degrees clockwise, 0/90/180/270
    var isHDR: Bool
    var hasAlpha: Bool = false

    /// Pixel size after the stored rotation is applied (what a person sees).
    var displaySize: (width: Int, height: Int) {
        rotation == 90 || rotation == 270 ? (height, width) : (width, height)
    }
}

struct AudioStreamInfo: Equatable {
    var codecName: String
    var codec: AudioCodec?
    var sampleRate: Int
    var channels: Int
    var bitrate: Int
}

/// What Fluxa knows about a source file after opening it. Produced by Apple's frameworks or by FFmpeg.
struct MediaProbe: Equatable {
    var containerName: String            // "mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm", "avi", ...
    var duration: Double                 // seconds
    var fileSize: Int64
    var bitrate: Int                     // bits per second, container level
    var video: VideoStreamInfo?
    var audio: [AudioStreamInfo]
    var subtitleCount: Int = 0
    var isProtected: Bool = false        // FairPlay / DRM
    /// True when Apple's frameworks can open and decode this file, so the fast native engine is allowed.
    var nativeReadable: Bool

    var hasVideo: Bool { video != nil }
    var hasAudio: Bool { !audio.isEmpty }
    var isAudioOnly: Bool { video == nil && !audio.isEmpty }
    var primaryAudio: AudioStreamInfo? { audio.first }
}

// MARK: - Output options

enum Resolution: Equatable, Hashable, Codable {
    case keep
    case uhd2160, qhd1440, hd1080, hd720, sd480, sd360
    case custom(height: Int)

    static let standardChoices: [Resolution] = [.keep, .uhd2160, .qhd1440, .hd1080, .hd720, .sd480, .sd360]

    /// Longest-side-independent target height in pixels. Nil keeps the source size.
    var height: Int? {
        switch self {
        case .keep: return nil
        case .uhd2160: return 2160
        case .qhd1440: return 1440
        case .hd1080: return 1080
        case .hd720: return 720
        case .sd480: return 480
        case .sd360: return 360
        case .custom(let h): return max(16, h)
        }
    }

    var title: String {
        switch self {
        case .keep: return "Original"
        case .uhd2160: return "4K"
        case .qhd1440: return "1440p"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        case .sd360: return "360p"
        case .custom(let h): return "\(h)p"
        }
    }
}

enum QualityLevel: Int, CaseIterable, Codable, Hashable {
    case low = 0, balanced, high, maximum

    var title: String {
        switch self {
        case .low: return "Small"
        case .balanced: return "Balanced"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    /// Bits per pixel per frame for a modern codec such as H.264.
    var bitsPerPixel: Double {
        switch self {
        case .low: return 0.045
        case .balanced: return 0.075
        case .high: return 0.115
        case .maximum: return 0.18
        }
    }
}

enum Rotation: Int, CaseIterable, Codable, Hashable {
    case none = 0, cw90 = 90, cw180 = 180, ccw90 = 270

    var title: String {
        switch self {
        case .none: return "None"
        case .cw90: return "90° right"
        case .cw180: return "180°"
        case .ccw90: return "90° left"
        }
    }

    func next() -> Rotation {
        switch self {
        case .none: return .cw90
        case .cw90: return .cw180
        case .cw180: return .ccw90
        case .ccw90: return .none
        }
    }
}

struct GifOptions: Equatable, Codable {
    var fps: Double = 12
    var maxWidth: Int = 480
    var maxColors: Int = 128
    var loops: Bool = true
    var dither: Bool = true
}

/// Everything a conversion needs besides the source file. A nil value means "keep what the source has".
struct OutputSpec: Equatable {
    var format: OutputFormat = .mp4
    var videoCodec: VideoCodec? = nil
    var audioCodec: AudioCodec? = nil
    var resolution: Resolution = .keep
    var fps: Double? = nil
    var quality: QualityLevel = .high
    var videoBitrateKbps: Int? = nil
    var audioBitrateKbps: Int? = nil
    var audioSampleRate: Int? = nil
    var rotation: Rotation = .none
    var flipHorizontal: Bool = false
    var trim: ClosedRange<Double>? = nil
    var stripMetadata: Bool = false
    var tonemapHDR: Bool = true
    var mute: Bool = false
    var gif: GifOptions = GifOptions()

    /// The codec that will really be used for video, after applying the container default.
    var resolvedVideoCodec: VideoCodec? {
        guard format.category == .video else { return nil }
        if let videoCodec, format.videoCodecs.contains(videoCodec) { return videoCodec }
        return format.defaultVideoCodec
    }

    var resolvedAudioCodec: AudioCodec? {
        if mute && format.category == .video { return nil }
        if let audioCodec, format.audioCodecs.contains(audioCodec) { return audioCodec }
        return format.defaultAudioCodec
    }

    /// True when the person asked for something that touches the picture, so video cannot be copied as it is.
    var altersPicture: Bool {
        resolution != .keep || fps != nil || rotation != .none || flipHorizontal || trim != nil || videoBitrateKbps != nil
    }

    /// True when the person asked for something that touches the sound, so audio cannot be copied as it is.
    var altersSound: Bool {
        audioBitrateKbps != nil || audioSampleRate != nil || trim != nil
    }
}
