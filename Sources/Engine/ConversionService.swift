import Foundation

/// The one entry point the app uses: open a file, plan a conversion, run it on the right engine.
final class ConversionService: @unchecked Sendable {
    static let shared = ConversionService()

    let native = NativeEngine()
    let ffmpeg: FFmpegEngine?

    init(ffmpegBridge: FFmpegBridge? = FFmpegBridgeProvider.makeBridge()) {
        if let ffmpegBridge { ffmpeg = FFmpegEngine(bridge: ffmpegBridge) } else { ffmpeg = nil }
    }

    var ffmpegAvailable: Bool { ffmpeg != nil }

    // MARK: Probe

    /// Opens the file with Apple's frameworks first (fast, exact), then with FFmpeg for everything else.
    func probe(url: URL) async throws -> MediaProbe {
        let ext = url.pathExtension.lowercased()
        var nativeError: Error?
        if InputFormats.appleExtensions.contains(ext) || ffmpeg == nil || ext.isEmpty {
            do {
                var probe = try await native.probe(url: url)
                if probe.nativeReadable || ffmpeg == nil || probe.isProtected { return probe }
                // Apple can open the container but not decode every track: ask FFmpeg for the detail, keep it as a fallback.
                if let ff = try? await ffmpeg?.probe(url: url) {
                    probe = ff
                    probe.nativeReadable = false
                    return probe
                }
                return probe
            } catch {
                nativeError = error
            }
        }
        if let ffmpeg {
            return try await ffmpeg.probe(url: url)
        }
        if let nativeError { throw nativeError }
        throw ConversionError.needsAdvancedEngine
    }

    // MARK: Plan

    func plan(probe: MediaProbe, spec: OutputSpec) throws -> ConversionPlan {
        try FormatMatrix.plan(probe: probe, spec: spec, ffmpegAvailable: ffmpegAvailable)
    }

    // MARK: Convert

    /// Runs the plan. If Apple's engine cannot read the file and FFmpeg can, the conversion continues on FFmpeg.
    /// Returns the URL of the finished file inside the exports folder.
    func convert(
        source: URL,
        displayName: String,
        probe: MediaProbe,
        spec: OutputSpec,
        plan: ConversionPlan,
        progress: @escaping @Sendable (TranscodeProgress) -> Void
    ) async throws -> URL {
        let output = Workspace.newOutputURL(fileName: OutputNamer.fileName(source: displayName, format: spec.format))
        let job = TranscodeJob(id: UUID(), source: source, probe: probe, spec: spec, plan: plan, output: output)
        do {
            try await engine(for: plan.engine).run(job, progress: progress)
            return output
        } catch let error as ConversionError {
            if error == .cancelled { throw error }
            if let fallback = plan.fallback, ffmpeg != nil, Self.shouldFallBack(error) {
                var retry = plan
                retry.engine = fallback
                retry.fallback = nil
                let fallbackJob = TranscodeJob(id: UUID(), source: source, probe: probe, spec: spec, plan: retry, output: output)
                try await engine(for: fallback).run(fallbackJob, progress: progress)
                return output
            }
            throw error
        }
    }

    static func shouldFallBack(_ error: ConversionError) -> Bool {
        switch error {
        case .unreadable, .engineFailed, .unsupportedCombination: return true
        default: return false
        }
    }

    private func engine(for kind: EngineKind) throws -> TranscodeEngine {
        switch kind {
        case .native: return native
        case .ffmpeg:
            guard let ffmpeg else { throw ConversionError.needsAdvancedEngine }
            return ffmpeg
        }
    }
}
