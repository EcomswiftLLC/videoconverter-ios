import SwiftUI
import Photos
import UIKit

/// Saving and sharing finished files. Every entry point goes through the rewarded gate first (free when no ad is ready).
@MainActor
enum Exporting {
    /// Formats the Photos library accepts.
    static func canSaveToPhotos(_ format: OutputFormat) -> Bool {
        [.mp4, .mov, .m4v, .threeGP, .gif].contains(format)
    }

    static func canPreview(_ format: OutputFormat) -> Bool {
        [.mp4, .mov, .m4v, .threeGP, .m4a, .wav, .aiff, .caf, .mp3].contains(format)
    }

    /// Share sheet (Messages, Mail, AirDrop, Save to Files, other apps).
    static func share(urls: [URL], completion: @escaping (Bool) -> Void) {
        guard !urls.isEmpty, let presenter = AdsPresenter.topViewController() else { completion(false); return }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            completion(completed)
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    /// The Files app: choose a folder, iCloud Drive, a USB drive or a network share.
    static func saveToFiles(urls: [URL], completion: @escaping (Bool) -> Void) {
        guard !urls.isEmpty, let presenter = AdsPresenter.topViewController() else { completion(false); return }
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        let coordinator = FilesPickerDelegate(completion: completion)
        picker.delegate = coordinator
        objc_setAssociatedObject(picker, filesDelegateKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
    }

    /// Adds videos and GIFs to the Photos library. Returns how many were saved.
    static func saveToPhotos(items: [(URL, OutputFormat)]) async -> Result<Int, Error> {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .failure(ExportError.photosDenied)
        }
        var saved = 0
        for (url, format) in items where canSaveToPhotos(format) {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = url.lastPathComponent
                    options.shouldMoveFile = false
                    request.addResource(with: format == .gif ? .photo : .video, fileURL: url, options: options)
                }
                saved += 1
            } catch {
                return .failure(error)
            }
        }
        return .success(saved)
    }

    enum ExportError: LocalizedError {
        case photosDenied
        var errorDescription: String? {
            "Fluxa needs permission to add to your photo library. You can allow it in Settings > Privacy & Security > Photos."
        }
    }
}

private let filesDelegateKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

private final class FilesPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completion(true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(false)
    }
}
