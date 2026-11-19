import Foundation

/// Turns the JSON that FFmpeg's probe prints (`-show_format -show_streams -of json`) into a `MediaProbe`.
/// Pure and tested, so the FFmpeg engine only has to hand over the text.
enum FFmpegProbeParser {
    static func parse(json: String, fileSize: Int64) throws -> MediaProbe {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConversionError.unreadable("probe output")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = root["streams"] as? [[String: Any]] ?? []

        var video: VideoStreamInfo?
        var audio: [AudioStreamInfo] = []
        var subtitles = 0

        for stream in streams {
            let type = stream["codec_type"] as? String ?? ""
            let name = stream["codec_name"] as? String ?? "unknown"
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            let attachedPicture = (disposition["attached_pic"] as? Int ?? 0) == 1
            switch type {
            case "video":
                if attachedPicture || video != nil { continue }
                let width = intValue(stream["width"])
                let height = intValue(stream["height"])
                var fps = rate(stream["avg_frame_rate"] as? String)
                if fps <= 0 || fps > 240 { fps = rate(stream["r_frame_rate"] as? String) }
                if fps <= 0 || fps > 240 { fps = 25 }
                var rotation = 0
                if let tags = stream["tags"] as? [String: Any], let r = tags["rotate"] { rotation = normalise(intValue(r)) }
                if let sides = stream["side_data_list"] as? [[String: Any]] {
                    for side in sides {
                        if let r = side["rotation"] {
                            // FFmpeg reports counter-clockwise degrees; the app uses clockwise.
                            rotation = normalise(-intValue(r))
                        }
                    }
                }
                let transfer = stream["color_transfer"] as? String ?? ""
                let pix = stream["pix_fmt"] as? String ?? ""
                video = VideoStreamInfo(
                    codecName: name,
                    codec: VideoCodec.fromName(name),
                    width: width, height: height, fps: fps,
                    bitrate: intValue(stream["bit_rate"]),
                    rotation: rotation,
                    isHDR: transfer == "smpte2084" || transfer == "arib-std-b67",
                    hasAlpha: pix.hasPrefix("yuva") || pix.hasPrefix("rgba") || pix.hasPrefix("bgra") || pix.hasPrefix("argb") || pix.hasPrefix("gbrap")
                )
            case "audio":
                audio.append(AudioStreamInfo(
                    codecName: name,
                    codec: AudioCodec.fromName(name),
                    sampleRate: intValue(stream["sample_rate"]),
                    channels: intValue(stream["channels"]),
                    bitrate: intValue(stream["bit_rate"])
                ))
            case "subtitle":
                subtitles += 1
            default:
                break
            }
        }

        if video == nil && audio.isEmpty { throw ConversionError.unreadable("no audio or video streams") }

        let duration = doubleValue(format["duration"])
        let size = Int64(intValue(format["size"]))
        return MediaProbe(
            containerName: format["format_name"] as? String ?? "unknown",
            duration: duration,
            fileSize: size > 0 ? size : fileSize,
            bitrate: intValue(format["bit_rate"]),
            video: video,
            audio: audio,
            subtitleCount: subtitles,
            isProtected: false,
            nativeReadable: false
        )
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) ?? Int(Double(s) ?? 0) }
        return 0
    }

    private static func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }

    /// "30000/1001" to 29.97.
    static func rate(_ text: String?) -> Double {
        guard let text else { return 0 }
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return Double(text) ?? 0
    }

    private static func normalise(_ degrees: Int) -> Int {
        let d = ((degrees % 360) + 360) % 360
        return [0, 90, 180, 270].min(by: { abs($0 - d) < abs($1 - d) }) ?? 0
    }
}
