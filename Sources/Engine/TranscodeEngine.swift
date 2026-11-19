import Foundation

/// One conversion, ready to run: a source, a spec, the plan that was chosen for it and where the result goes.
struct TranscodeJob {
    let id: UUID
    let source: URL
    let probe: MediaProbe
    let spec: OutputSpec
    let plan: ConversionPlan
    let output: URL
}

struct TranscodeProgress: Equatable {
    /// 0...1 of the output duration written so far.
    var fraction: Double
    /// Encoding speed relative to real time, when known (2.0 means twice as fast as playback).
    var speed: Double?
}

/// An engine turns a `TranscodeJob` into a file. Both engines (Apple's frameworks and FFmpeg) conform, so the queue never
/// cares which one runs. Cancel by cancelling the Swift task that calls `run`.
protocol TranscodeEngine: AnyObject {
    var kind: EngineKind { get }
    func probe(url: URL) async throws -> MediaProbe
    func run(_ job: TranscodeJob, progress: @escaping @Sendable (TranscodeProgress) -> Void) async throws
}

/// Thread-safe cancel flag used by the pumps that copy sample buffers on background queues.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }
}

/// Free space check shared by both engines.
enum DiskSpace {
    static func available() -> Int64 {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            return bytes
        }
        return Int64.max
    }

    /// Throws `.diskFull` when the expected output (plus a safety margin) cannot fit.
    static func ensure(estimatedBytes: Int64?) throws {
        let need = (estimatedBytes ?? 0) + 150 * 1024 * 1024
        if available() < need { throw ConversionError.diskFull }
    }
}

/// Where converted files live until the person saves or shares them.
enum Workspace {
    static var exportsFolder: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FluxaExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var importsFolder: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FluxaImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh, unique output URL with a readable name inside its own folder (so two jobs can share a file name).
    static func newOutputURL(fileName: String) -> URL {
        let folder = exportsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    static func clearAll() {
        for folder in [exportsFolder, importsFolder] {
            if let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for item in items { try? FileManager.default.removeItem(at: item) }
            }
        }
    }
}
