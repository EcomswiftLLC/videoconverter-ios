import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

/// One file the person chose, with what Fluxa learned about it and how its conversion is going.
@MainActor
final class ConversionItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case probing
        case ready
        case waiting
        case running
        case done
        case failed(ConversionError)
        case cancelled
    }

    let id = UUID()
    let sourceURL: URL
    let displayName: String
    /// True when the file sits outside the app and needs security-scoped access for as long as the item lives.
    private let scoped: Bool

    @Published var state: State = .probing
    @Published var probe: MediaProbe?
    @Published var probeError: ConversionError?
    @Published var progress: Double = 0
    @Published var speed: Double?
    @Published var resultURL: URL?
    @Published var resultBytes: Int64 = 0
    @Published var plan: ConversionPlan?
    @Published var planError: ConversionError?
    @Published var thumbnail: UIImage?

    fileprivate var task: Task<Void, Never>?
    fileprivate var cancelRun: (() -> Void)?

    init(sourceURL: URL, displayName: String, scoped: Bool) {
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.scoped = scoped
        if scoped { _ = sourceURL.startAccessingSecurityScopedResource() }
    }

    deinit {
        if scoped { sourceURL.stopAccessingSecurityScopedResource() }
    }

    var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }
}

/// The list of files being converted, one after another. Conversion happens here; saving and sharing (behind the
/// rewarded ad) happens in the result screen.
@MainActor
final class ConversionQueue: ObservableObject {
    @Published private(set) var items: [ConversionItem] = []
    @Published var spec = OutputSpec()
    @Published private(set) var isRunning = false
    @Published var notice: String?

    private let service: ConversionService
    private var runner: Task<Void, Never>?

    init(service: ConversionService = .shared) {
        self.service = service
    }

    var ffmpegAvailable: Bool { service.ffmpegAvailable }

    var readyItems: [ConversionItem] { items.filter { $0.probe != nil } }
    var doneItems: [ConversionItem] { items.filter { $0.state == .done } }
    var hasFinished: Bool { !items.isEmpty && items.allSatisfy { $0.isFinished } }
    var anyProbing: Bool { items.contains { $0.state == .probing } }

    #if DEBUG
    /// Debug screenshots only: shows the queue as if it were converting.
    func debugSetRunning(_ value: Bool) { isRunning = value }
    #endif

    // MARK: Adding files

    /// Files chosen in the Files app or dropped from another app.
    func add(urls: [URL], scoped: Bool) {
        for url in urls {
            let item = ConversionItem(sourceURL: url, displayName: url.lastPathComponent, scoped: scoped)
            items.append(item)
            probe(item)
        }
    }

    /// A file that already lives in the app's own folder (from the Photos picker or a drop).
    func addLocal(url: URL, displayName: String) {
        let item = ConversionItem(sourceURL: url, displayName: displayName, scoped: false)
        items.append(item)
        probe(item)
    }

    func remove(_ item: ConversionItem) {
        item.task?.cancel()
        item.cancelRun?()
        items.removeAll { $0.id == item.id }
        if let url = item.resultURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func removeAll() {
        runner?.cancel()
        for item in items { item.task?.cancel(); item.cancelRun?() }
        for item in items {
            if let url = item.resultURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        items.removeAll()
        isRunning = false
        spec = OutputSpec()
    }

    private func probe(_ item: ConversionItem) {
        item.task = Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let probe = try await self.service.probe(url: item.sourceURL)
                item.probe = probe
                item.state = .ready
                self.refreshPlan(for: item)
                if self.service.ffmpegAvailable || probe.nativeReadable {
                    item.thumbnail = await Thumbnailer.thumbnail(for: item.sourceURL, probe: probe)
                }
            } catch let error as ConversionError {
                item.probeError = error
                item.state = .failed(error)
            } catch {
                let mapped = ConversionError.unreadable(error.localizedDescription)
                item.probeError = mapped
                item.state = .failed(mapped)
            }
        }
    }

    // MARK: Planning

    func refreshPlans() {
        for item in items where item.probe != nil && !item.isFinished && item.state != .running {
            refreshPlan(for: item)
        }
    }

    private func refreshPlan(for item: ConversionItem) {
        guard let probe = item.probe else { return }
        do {
            item.plan = try service.plan(probe: probe, spec: spec)
            item.planError = nil
        } catch let error as ConversionError {
            item.plan = nil
            item.planError = error
        } catch {
            item.plan = nil
            item.planError = .engineFailed(error.localizedDescription)
        }
    }

    /// Items that can be converted with the current settings.
    var convertibleItems: [ConversionItem] {
        items.filter { $0.probe != nil && $0.plan != nil && $0.planError == nil && !$0.isFinished }
    }

    func estimatedTotalBytes() -> Int64 {
        convertibleItems.reduce(0) { total, item in
            guard let probe = item.probe else { return total }
            return total + (BitrateEstimator.estimatedBytes(probe: probe, spec: spec, plan: item.plan) ?? 0)
        }
    }

    // MARK: Running

    func start() {
        guard !isRunning else { return }
        let snapshot = spec
        let work = convertibleItems
        guard !work.isEmpty else { return }
        for item in work { item.state = .waiting; item.progress = 0 }
        isRunning = true
        runner = Task { [weak self] in
            guard let self else { return }
            for item in work {
                if Task.isCancelled { break }
                await self.run(item, spec: snapshot)
            }
            self.isRunning = false
        }
    }

    private func run(_ item: ConversionItem, spec: OutputSpec) async {
        guard item.state == .waiting, let probe = item.probe else { return }
        // Re-plan with the settings captured when the person pressed Convert.
        let plan: ConversionPlan
        do { plan = try service.plan(probe: probe, spec: spec) } catch let error as ConversionError {
            item.state = .failed(error)
            return
        } catch {
            item.state = .failed(.engineFailed(error.localizedDescription))
            return
        }
        item.plan = plan
        item.state = .running
        let service = self.service
        let url = item.sourceURL
        let name = item.displayName
        let task = Task { () -> Result<URL, Error> in
            do {
                let out = try await service.convert(source: url, displayName: name, probe: probe, spec: spec, plan: plan) { p in
                    Task { @MainActor [weak item] in
                        item?.progress = p.fraction
                        item?.speed = p.speed
                    }
                }
                return .success(out)
            } catch {
                return .failure(error)
            }
        }
        item.cancelRun = { task.cancel() }
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        item.cancelRun = nil
        switch outcome {
        case .success(let out):
            item.resultURL = out
            item.resultBytes = NativeEngine.fileSize(out)
            item.progress = 1
            item.state = .done
        case .failure(let error):
            if let conversion = error as? ConversionError {
                item.state = conversion == .cancelled ? .cancelled : .failed(conversion)
            } else if error is CancellationError {
                item.state = .cancelled
            } else {
                item.state = .failed(NativeEngine.map(error))
            }
        }
    }

    func cancel(_ item: ConversionItem) {
        if item.state == .running || item.state == .waiting {
            item.cancelRun?()
            if item.state == .waiting { item.state = .cancelled }
        }
    }

    func cancelAll() {
        runner?.cancel()
        for item in items where item.state == .running || item.state == .waiting {
            item.cancelRun?()
            if item.state == .waiting { item.state = .cancelled }
        }
    }

    /// Back to the setup screen with the same files, e.g. to try another format.
    func resetResults() {
        for item in items where item.isFinished && item.probe != nil {
            if let url = item.resultURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            item.resultURL = nil
            item.progress = 0
            item.state = .ready
            refreshPlan(for: item)
        }
    }
}

// MARK: - Thumbnails

enum Thumbnailer {
    static func thumbnail(for url: URL, probe: MediaProbe) async -> UIImage? {
        guard probe.hasVideo, probe.nativeReadable else { return nil }
        return await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let time = CMTime(seconds: min(1, max(0, probe.duration / 4)), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}
