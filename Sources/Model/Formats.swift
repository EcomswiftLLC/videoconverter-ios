import Foundation
import UniformTypeIdentifiers

// MARK: - Codecs

enum VideoCodec: String, CaseIterable, Codable, Hashable {
    case h264, hevc, vp9, vp8, mpeg4, mpeg2, wmv2, flv1, mjpeg, prores, theora, h263

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .vp9: return "VP9"
        case .vp8: return "VP8"
        case .mpeg4: return "MPEG-4"
        case .mpeg2: return "MPEG-2"
        case .wmv2: return "WMV 8"
        case .flv1: return "Sorenson H.263"
        case .mjpeg: return "Motion JPEG"
        case .prores: return "ProRes 422"
        case .theora: return "Theora"
        case .h263: return "H.263"
        }
    }

    /// Codecs Apple's AVFoundation can encode in hardware or software on every supported device.
    var isNativeEncodable: Bool { self == .h264 || self == .hevc }

    /// The FFmpeg encoder name.
    var ffmpegEncoder: String {
        switch self {
        case .h264: return "h264_videotoolbox"
        case .hevc: return "hevc_videotoolbox"
        case .vp9: return "libvpx-vp9"
        case .vp8: return "libvpx"
        case .mpeg4: return "mpeg4"
        case .mpeg2: return "mpeg2video"
        case .wmv2: return "wmv2"
        case .flv1: return "flv"
        case .mjpeg: return "mjpeg"
        case .prores: return "prores_ks"
        case .theora: return "libtheora"
        case .h263: return "h263"
        }
    }

    /// Maps an FFmpeg or AVFoundation codec name to a codec Fluxa knows. Nil for codecs that are only ever read.
    static func fromName(_ raw: String) -> VideoCodec? {
        let name = raw.lowercased()
        switch name {
        case "h264", "avc1", "avc", "x264": return .h264
        case "hevc", "h265", "hvc1", "hev1": return .hevc
        case "vp9", "vp09": return .vp9
        case "vp8", "vp08": return .vp8
        case "mpeg4", "mp4v", "xvid", "divx", "dx50": return .mpeg4
        case "mpeg2video", "mpeg2", "mp2v": return .mpeg2
        case "wmv2", "wmv8": return .wmv2
        case "flv1", "flv": return .flv1
        case "mjpeg", "jpeg", "mjpg": return .mjpeg
        case "prores", "ap4h", "apch", "apcn", "apcs", "apco": return .prores
        case "theora": return .theora
        case "h263", "s263": return .h263
        default: return nil
        }
    }
}

enum AudioCodec: String, CaseIterable, Codable, Hashable {
    case aac, mp3, opus, vorbis, flac, ac3, alac, pcm, wmav2, amrnb

    var displayName: String {
        switch self {
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .opus: return "Opus"
        case .vorbis: return "Vorbis"
        case .flac: return "FLAC"
        case .ac3: return "Dolby Digital (AC-3)"
        case .alac: return "Apple Lossless"
        case .pcm: return "PCM (uncompressed)"
        case .wmav2: return "WMA"
        case .amrnb: return "AMR"
        }
    }

    var ffmpegEncoder: String {
        switch self {
        case .aac: return "aac"
        case .mp3: return "libmp3lame"
        case .opus: return "libopus"
        case .vorbis: return "libvorbis"
        case .flac: return "flac"
        case .ac3: return "ac3"
        case .alac: return "alac"
        case .pcm: return "pcm_s16le"
        case .wmav2: return "wmav2"
        case .amrnb: return "libopencore_amrnb"
        }
    }

    var isLossless: Bool { self == .flac || self == .alac || self == .pcm }

    /// Typical bitrates offered for lossy codecs, in kbit/s. Empty for lossless codecs.
    var bitrateChoices: [Int] {
        switch self {
        case .aac: return [96, 128, 192, 256, 320]
        case .mp3: return [96, 128, 192, 256, 320]
        case .opus: return [64, 96, 128, 192, 256]
        case .vorbis: return [96, 128, 192, 256, 320]
        case .ac3: return [192, 384, 448, 640]
        case .wmav2: return [96, 128, 192, 320]
        default: return []
        }
    }

    var defaultBitrate: Int {
        switch self {
        case .aac: return 192
        case .mp3: return 192
        case .opus: return 128
        case .vorbis: return 160
        case .ac3: return 384
        case .wmav2: return 192
        default: return 0
        }
    }

    static func fromName(_ raw: String) -> AudioCodec? {
        let name = raw.lowercased()
        if name.hasPrefix("pcm_") || name == "lpcm" || name == "pcm" || name == "sowt" || name == "twos" || name == "in24" || name == "in32" { return .pcm }
        switch name {
        case "aac", "mp4a", "aac_latm": return .aac
        case "mp3", "mp3float", ".mp3", "mpga": return .mp3
        case "opus": return .opus
        case "vorbis": return .vorbis
        case "flac": return .flac
        case "ac3", "ac-3", "eac3", "ec-3": return .ac3
        case "alac": return .alac
        case "wmav2", "wmav1", "wmapro": return .wmav2
        case "amr_nb", "samr", "amrnb": return .amrnb
        default: return nil
        }
    }
}

// MARK: - Output formats

enum FormatCategory: String, CaseIterable, Codable {
    case video, audio, image

    var title: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Animated image"
        }
    }
}

/// Which engine can write a target. `.nativeOrFFmpeg` targets can be written by Apple's frameworks for the common codecs.
enum EngineSupport: String, Codable {
    case nativeOrFFmpeg
    case ffmpegOnly
}

/// Every output format Fluxa writes. One case per file type shown in the format grid.
enum OutputFormat: String, CaseIterable, Codable, Hashable, Identifiable {
    // Video containers
    case mp4, mov, m4v, threeGP, mkv, webm, avi, flv, wmv, mpg, ts, ogv
    // Audio only
    case m4a, mp3, wav, aiff, caf, flac, ogg, opus, ac3
    // Animated images
    case gif, webp, apng

    var id: String { rawValue }

    var category: FormatCategory {
        switch self {
        case .mp4, .mov, .m4v, .threeGP, .mkv, .webm, .avi, .flv, .wmv, .mpg, .ts, .ogv: return .video
        case .m4a, .mp3, .wav, .aiff, .caf, .flac, .ogg, .opus, .ac3: return .audio
        case .gif, .webp, .apng: return .image
        }
    }

    var displayName: String {
        switch self {
        case .threeGP: return "3GP"
        case .ts: return "MPEG-TS"
        case .mpg: return "MPG"
        default: return rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .threeGP: return "3gp"
        case .ts: return "ts"
        default: return rawValue
        }
    }

    var utType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .m4v: return UTType("com.apple.m4v-video") ?? .mpeg4Movie
        case .threeGP: return UTType("public.3gpp") ?? .movie
        case .mkv: return UTType("org.matroska.mkv") ?? UTType(filenameExtension: "mkv") ?? .movie
        case .webm: return UTType("org.webmproject.webm") ?? UTType(filenameExtension: "webm") ?? .movie
        case .avi: return .avi
        case .flv: return UTType("com.adobe.flash-video") ?? UTType(filenameExtension: "flv") ?? .movie
        case .wmv: return UTType("com.microsoft.windows-media-wmv") ?? UTType(filenameExtension: "wmv") ?? .movie
        case .mpg: return .mpeg
        case .ts: return UTType("public.mpeg-2-transport-stream") ?? UTType(filenameExtension: "ts") ?? .movie
        case .ogv: return UTType(filenameExtension: "ogv") ?? .movie
        case .m4a: return .mpeg4Audio
        case .mp3: return .mp3
        case .wav: return .wav
        case .aiff: return .aiff
        case .caf: return UTType("com.apple.coreaudio-format") ?? .audio
        case .flac: return UTType("org.xiph.flac") ?? UTType(filenameExtension: "flac") ?? .audio
        case .ogg: return UTType("org.xiph.ogg-audio") ?? UTType(filenameExtension: "ogg") ?? .audio
        case .opus: return UTType(filenameExtension: "opus") ?? .audio
        case .ac3: return UTType(filenameExtension: "ac3") ?? .audio
        case .gif: return .gif
        case .webp: return .webP
        case .apng: return .png
        }
    }

    /// Video codecs the container can hold, best first. The first one is the default.
    var videoCodecs: [VideoCodec] {
        switch self {
        case .mp4, .m4v: return [.h264, .hevc, .mpeg4, .vp9]
        case .mov: return [.h264, .hevc, .prores, .mjpeg, .mpeg4]
        case .threeGP: return [.h264, .mpeg4]
        case .mkv: return [.h264, .hevc, .vp9, .vp8, .mpeg4, .theora]
        case .webm: return [.vp9, .vp8]
        case .avi: return [.mpeg4, .h264, .mjpeg, .wmv2]
        case .flv: return [.h264, .flv1]
        case .wmv: return [.wmv2, .mpeg4]
        case .mpg: return [.mpeg2, .mpeg4]
        case .ts: return [.h264, .hevc, .mpeg2]
        case .ogv: return [.theora]
        default: return []
        }
    }

    var defaultVideoCodec: VideoCodec? { videoCodecs.first }

    /// Audio codecs the container can hold, best first. Empty means "no audio" (image formats).
    var audioCodecs: [AudioCodec] {
        switch self {
        case .mp4, .m4v: return [.aac, .mp3, .ac3, .alac]
        case .mov: return [.aac, .alac, .pcm, .mp3]
        case .threeGP: return [.aac]
        case .mkv: return [.aac, .opus, .vorbis, .mp3, .flac, .ac3, .pcm]
        case .webm: return [.opus, .vorbis]
        case .avi: return [.mp3, .aac, .ac3, .pcm]
        case .flv: return [.aac, .mp3]
        case .wmv: return [.wmav2]
        case .mpg: return [.ac3, .mp3]
        case .ts: return [.aac, .ac3, .mp3]
        case .ogv: return [.vorbis, .opus]
        case .m4a: return [.aac, .alac]
        case .mp3: return [.mp3]
        case .wav, .aiff, .caf: return [.pcm]
        case .flac: return [.flac]
        case .ogg: return [.vorbis, .opus]
        case .opus: return [.opus]
        case .ac3: return [.ac3]
        case .gif, .webp, .apng: return []
        }
    }

    var defaultAudioCodec: AudioCodec? { audioCodecs.first }

    /// Whether Apple's frameworks can write this container at all (with the right codecs).
    var engineSupport: EngineSupport {
        switch self {
        case .mp4, .mov, .m4v, .threeGP, .m4a, .wav, .aiff, .caf, .gif, .apng: return .nativeOrFFmpeg
        default: return .ffmpegOnly
        }
    }

    var avFileTypeName: String? {
        switch self {
        case .mp4: return "public.mpeg-4"
        case .mov: return "com.apple.quicktime-movie"
        case .m4v: return "com.apple.m4v-video"
        case .threeGP: return "public.3gpp"
        case .m4a: return "com.apple.m4a-audio"
        case .wav: return "com.microsoft.waveform-audio"
        case .aiff: return "public.aiff-audio"
        case .caf: return "com.apple.coreaudio-format"
        default: return nil
        }
    }

    var summary: String {
        switch self {
        case .mp4: return "Plays almost everywhere. The safe choice."
        case .mov: return "Apple's format. Best for editing on a Mac."
        case .m4v: return "MP4 for iTunes and Apple TV."
        case .threeGP: return "Tiny files for old phones and MMS."
        case .mkv: return "Holds any codec, many audio tracks and subtitles."
        case .webm: return "Open web video for browsers and Android."
        case .avi: return "Classic Windows video, old players."
        case .flv: return "Flash video for legacy sites and tools."
        case .wmv: return "Windows Media for older PCs and Office."
        case .mpg: return "MPEG-2 for DVD players and old TVs."
        case .ts: return "Broadcast streams, AVCHD and IPTV."
        case .ogv: return "Open Theora video for Linux players."
        case .m4a: return "AAC audio. Great quality in small files."
        case .mp3: return "Plays on every device ever made."
        case .wav: return "Uncompressed audio for editing."
        case .aiff: return "Apple's uncompressed audio."
        case .caf: return "Core Audio, for GarageBand and Logic."
        case .flac: return "Lossless audio at half the size of WAV."
        case .ogg: return "Open Vorbis audio, popular in games."
        case .opus: return "The most efficient voice and music codec."
        case .ac3: return "Dolby Digital for home theatre."
        case .gif: return "Silent looping clip that works in any chat."
        case .webp: return "Animated WebP, smaller than GIF."
        case .apng: return "Animated PNG with full colour."
        }
    }

    static func formats(in category: FormatCategory) -> [OutputFormat] {
        allCases.filter { $0.category == category }
    }
}

// MARK: - Input formats

/// What the file picker accepts and what the Formats guide lists as readable. The set is anything AVFoundation or FFmpeg can open.
enum InputFormats {
    struct Group: Identifiable {
        let id: String
        let title: String
        let extensions: [String]
        let engine: String
    }

    static let groups: [Group] = [
        Group(id: "apple", title: "Apple video", extensions: ["mp4", "mov", "m4v", "3gp", "3g2", "hevc", "heic", "qt"], engine: "Apple"),
        Group(id: "open", title: "Open and web video", extensions: ["mkv", "webm", "ogv", "ogg", "ogm", "gif", "webp", "apng"], engine: "FFmpeg"),
        Group(id: "windows", title: "Windows and legacy video", extensions: ["avi", "wmv", "asf", "flv", "f4v", "rm", "rmvb", "divx", "xvid"], engine: "FFmpeg"),
        Group(id: "broadcast", title: "Camera, DVD and broadcast", extensions: ["mpg", "mpeg", "mpe", "vob", "ts", "m2ts", "mts", "mxf", "dv", "mjpeg", "m2v"], engine: "FFmpeg"),
        Group(id: "audio", title: "Audio", extensions: ["mp3", "aac", "m4a", "wav", "aiff", "aif", "caf", "flac", "oga", "opus", "wma", "amr", "ac3", "eac3", "mka"], engine: "Apple and FFmpeg")
    ]

    static var allExtensions: [String] {
        var seen = Set<String>()
        return groups.flatMap { $0.extensions }.filter { seen.insert($0).inserted }
    }

    /// Content types for the Files and drag-and-drop pickers. Unknown extensions fall back to generic movie and audio.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mp3, .wav, .aiff, .gif, .webP, .item]
        for ext in allExtensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    static let audioOnlyExtensions: Set<String> = ["mp3", "aac", "m4a", "wav", "aiff", "aif", "caf", "flac", "oga", "opus", "wma", "amr", "ac3", "eac3", "mka"]

    static func isAudioOnlyExtension(_ ext: String) -> Bool { audioOnlyExtensions.contains(ext.lowercased()) }

    /// Extensions AVFoundation opens on its own. Everything else needs the FFmpeg engine.
    static let appleExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "3g2", "qt", "m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "ac3", "eac3", "amr", "heic", "hevc"]
}
