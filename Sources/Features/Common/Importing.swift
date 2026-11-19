import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A video chosen in the Photos picker, copied into the app's own folder so it can be read at any time.
struct PickedMovie: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let folder = Workspace.importsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let target = folder.appendingPathComponent("Video.\(ext)")
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target, name: target.lastPathComponent)
        }
    }
}

enum Importing {
    /// Copies a dropped or shared file into the imports folder and returns the copy.
    static func copyIntoImports(_ source: URL, name: String? = nil) throws -> URL {
        let folder = Workspace.importsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// Handles items dropped on the Home screen (iPad drag and drop from Files, Photos, Safari and other apps).
    @MainActor
    static func handleDrop(providers: [NSItemProvider], into queue: ConversionQueue) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
            accepted = true
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { return }
                // The system deletes the provided file when this closure returns, so copy it first.
                guard let copy = try? copyIntoImports(url) else { return }
                Task { @MainActor in queue.addLocal(url: copy, displayName: copy.lastPathComponent) }
            }
        }
        return accepted
    }

    /// Loads the Photos picker selection into the queue.
    @MainActor
    static func load(_ items: [PhotosPickerItem], into queue: ConversionQueue) async {
        for item in items {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                queue.addLocal(url: movie.url, displayName: movie.name)
            }
        }
    }
}

/// The three sample files bundled with the app, in three different formats, so anyone can try Fluxa without a file at hand.
struct SampleClip: Identifiable {
    let id: String
    let title: String
    let fileName: String
    let ext: String
    let caption: String

    static let all: [SampleClip] = [
        SampleClip(id: "waterfall", title: "Waterfall", fileName: "Waterfall", ext: "mp4", caption: "MP4 · H.264"),
        SampleClip(id: "beach", title: "Beach waves", fileName: "Beach-waves", ext: "mkv", caption: "MKV · H.264"),
        SampleClip(id: "smoke", title: "Night smoke", fileName: "Night-smoke", ext: "avi", caption: "AVI · MPEG-4")
    ]

    var bundleURL: URL? { Bundle.main.url(forResource: fileName, withExtension: ext) }

    /// A copy in the imports folder, named like a real file the person might have.
    func importCopy() -> URL? {
        guard let bundleURL else { return nil }
        return try? Importing.copyIntoImports(bundleURL, name: "\(title).\(ext)")
    }
}
