import Foundation

/// Connects the Swift engine to Fluxa's C wrapper around the LGPL FFmpeg libraries (`FluxaFF.c`).
/// It only exists as a working bridge when the libraries were linked into this build (`fx_available()`).
final class LGPLBridge: FFmpegBridge {
    let capabilities: FFmpegCapabilities
    private let cancelFlag: UnsafeMutablePointer<Int32>
    private var errorLine = ""

    init?() {
        guard fx_available() == 1 else { return nil }
        let wanted = ["h264_videotoolbox", "hevc_videotoolbox", "libvpx-vp9", "libvpx", "mpeg4", "mpeg2video", "wmv2", "flv", "mjpeg", "prores_ks",
                      "h263", "aac", "libmp3lame", "libopus", "libvorbis", "flac", "ac3", "alac", "pcm_s16le", "pcm_s16be", "wmav2", "libwebp_anim", "apng", "gif", "libtheora"]
        let found = Set(wanted.filter { fx_has_encoder($0) != 0 })
        capabilities = FFmpegCapabilities(hasZscale: fx_has_filter("zscale") != 0, encoders: found)
        cancelFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cancelFlag.initialize(to: 0)
    }

    deinit { cancelFlag.deallocate() }

    private final class ProgressBox {
        let callback: (Double, Double?) -> Void
        init(_ callback: @escaping (Double, Double?) -> Void) { self.callback = callback }
    }

    func execute(arguments: [String], onProgress: @escaping (Double, Double?) -> Void) -> Int32 {
        cancelFlag.pointee = 0
        let box = ProgressBox(onProgress)
        let context = Unmanaged.passRetained(box).toOpaque()
        var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        defer { for pointer in pointers { free(UnsafeMutablePointer(mutating: pointer)) } }

        let code = pointers.withUnsafeMutableBufferPointer { buffer -> Int32 in
            fx_execute(Int32(arguments.count), buffer.baseAddress, { seconds, speed, context in
                guard let context else { return }
                let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
                box.callback(seconds, speed > 0 ? speed : nil)
            }, context, cancelFlag)
        }
        Unmanaged<ProgressBox>.fromOpaque(context).release()
        errorLine = String(cString: fx_last_error())
        return code
    }

    func cancel() { cancelFlag.pointee = 1 }

    func probeJSON(path: String) -> String? {
        guard let raw = fx_probe_json(path) else { return nil }
        defer { fx_free(raw) }
        return String(cString: raw)
    }

    func lastErrorLine() -> String { errorLine }
}
