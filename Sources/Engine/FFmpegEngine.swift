import Foundation

/// The seam between Fluxa and the LGPL FFmpeg build. A concrete bridge is provided by `FFmpegBridgeProvider` once the
/// FFmpeg xcframework is linked; until then the app runs on Apple's engine only and says so honestly.
protocol FFmpegBridge: AnyObject {
    var capabilities: FFmpegCapabilities { get }
    /// Runs one FFmpeg command in-process and blocks until it ends. Returns 0 on success.
    /// `onProgress` receives the output time in seconds written so far and the speed multiple when known.
    func execute(arguments: [String], onProgress: @escaping (Double, Double?) -> Void) -> Int32
    /// Asks the running command to stop as soon as possible.
    func cancel()
    /// The probe JSON (`-show_format -show_streams`) for a file, or nil when it can't be opened.
    func probeJSON(path: String) -> String?
    /// The last error line FFmpeg logged, for the failure message.
    func lastErrorLine() -> String
}

/// Reads and writes every format Apple's frameworks cannot: MKV, WebM, AVI, FLV, WMV, MPG, TS, OGV, MP3, FLAC, OGG, Opus and more.
final class FFmpegEngine: TranscodeEngine {
    let kind: EngineKind = .ffmpeg
    private let bridge: FFmpegBridge
    /// FFmpeg's command-line core keeps global state, so only one command runs at a time.
    private static let runLock = NSLock()

    init(bridge: FFmpegBridge) { self.bridge = bridge }

    var capabilities: FFmpegCapabilities { bridge.capabilities }

    func probe(url: URL) async throws -> MediaProbe {
        let path = url.path
        let size = NativeEngine.fileSize(url)
        let json: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                Self.runLock.lock()
                let text = self.bridge.probeJSON(path: path)
                Self.runLock.unlock()
                continuation.resume(returning: text)
            }
        }
        guard let json else { throw ConversionError.unreadable("not a media file") }
        return try FFmpegProbeParser.parse(json: json, fileSize: size)
    }

    func run(_ job: TranscodeJob, progress: @escaping @Sendable (TranscodeProgress) -> Void) async throws {
        try? FileManager.default.removeItem(at: job.output)
        let estimate = BitrateEstimator.estimatedBytes(probe: job.probe, spec: job.spec, plan: job.plan)
        try DiskSpace.ensure(estimatedBytes: estimate)

        let args = FFmpegCommandBuilder.arguments(job: job, capabilities: bridge.capabilities)
        let total = max(BitrateEstimator.effectiveDuration(probe: job.probe, spec: job.spec), 0.001)
        let bridge = self.bridge
        let cancelFlag = CancelFlag()

        let code: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.runLock.lock()
                    if cancelFlag.isCancelled {
                        Self.runLock.unlock()
                        continuation.resume(returning: -1)
                        return
                    }
                    let result = bridge.execute(arguments: args) { time, speed in
                        progress(TranscodeProgress(fraction: min(0.99, max(0, time / total)), speed: speed))
                    }
                    Self.runLock.unlock()
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancelFlag.cancel()
            bridge.cancel()
        }

        if cancelFlag.isCancelled || Task.isCancelled {
            try? FileManager.default.removeItem(at: job.output)
            throw ConversionError.cancelled
        }
        guard code == 0, FileManager.default.fileExists(atPath: job.output.path) else {
            try? FileManager.default.removeItem(at: job.output)
            if DiskSpace.available() < 50 * 1024 * 1024 { throw ConversionError.diskFull }
            let line = bridge.lastErrorLine()
            throw Self.mapFailure(line)
        }
        progress(TranscodeProgress(fraction: 1, speed: nil))
    }

    /// Turns FFmpeg's last error line into a message a person can act on.
    static func mapFailure(_ line: String) -> ConversionError {
        let text = line.lowercased()
        if text.contains("no space left") { return .diskFull }
        if text.contains("invalid data found") || text.contains("moov atom not found") || text.contains("end of file") {
            return .unreadable("the file looks damaged or incomplete")
        }
        if text.contains("encrypted") || text.contains("drm") || text.contains("protected") { return .drmProtected }
        if text.contains("permission denied") { return .unreadable("no permission to read the file") }
        if text.contains("encoder") && text.contains("not found") { return .needsAdvancedEngine }
        return .engineFailed("")
    }
}

/// Finds the FFmpeg bridge of this build. Returns nil when the FFmpeg library is not linked.
enum FFmpegBridgeProvider {
    static func makeBridge() -> FFmpegBridge? {
        // nil when the FFmpeg libraries were not linked into this build.
        return LGPLBridge()
    }
}
