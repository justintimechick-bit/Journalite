import Foundation
import Observation
import PhotosUI
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
import VisionKit
import AVFoundation
#endif

nonisolated struct PickedImageFile: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let bytes = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes <= ImportLimits.imageBytes else { throw IngestionError.limit }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".picked")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedImageFile(url: copy)
        }
    }
}

nonisolated enum CameraDecision: Equatable {
    case scan, request, denied, unsupported
    static func resolve(supported: Bool, authorized: Bool, notDetermined: Bool) -> CameraDecision {
        guard supported else { return .unsupported }
        if authorized { return .scan }
        return notDetermined ? .request : .denied
    }
}

@MainActor
@Observable
final class CaptureCoordinator {
    var receipt: IngestionReceipt?
    var showReview = false
    var showScanner = false
    var message: String?
    var cameraDenied = false
    private(set) var busy = false
    private(set) var saving = false
    private(set) var recoveries: [IngestionReceipt] = []
    private(set) var duplicates: Set<UUID> = []
    private(set) var progress = ""
    let files: IngestionFiles
    private var loadingTask: Task<Void, Never>?
    private var preferredNotebook: UUID?
    private let preview: Bool

    init(preview: Bool) {
        self.preview = preview
        let root = preview
            ? FileManager.default.temporaryDirectory.appendingPathComponent("PreviewIngestion-" + UUID().uuidString)
            : URL.applicationSupportDirectory.appendingPathComponent("Journalite/Ingestion", isDirectory: true)
        files = IngestionFiles(root: root)
    }

    func refreshRecovery() async {
        do { recoveries = try await files.recoverable() }
        catch { message = "An ingestion receipt could not be read. Files were kept. Do not delete or reinstall the app; preserve a device backup before seeking recovery help." }
    }

    func defaultNotebook(viewing: UUID?, notebooks: [NotebookSummary]) -> UUID? {
        if let viewing, notebooks.contains(where: { $0.id == viewing }) { return viewing }
        if !preview, let raw = UserDefaults.standard.string(forKey: "lastCaptureNotebook"),
           let id = UUID(uuidString: raw), notebooks.contains(where: { $0.id == id }) { return id }
        return notebooks.first?.id
    }

    func startImport(_ items: [PhotosPickerItem], notebookID: UUID?, repository: JournalRepository) {
        guard !items.isEmpty, !busy, !showReview else { return }
        busy = true
        loadingTask = Task {
            do {
                receipt = try await files.begin(count: items.count, notebookID: notebookID)
                showReview = true
                duplicates = []
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    progress = "Loading photo \(index + 1) of \(items.count)"
                    do {
                        guard let loaded = try await item.loadTransferable(type: PickedImageFile.self) else { throw IngestionError.invalidImage }
                        defer { try? FileManager.default.removeItem(at: loaded.url) }
                        try Task.checkCancellation()
                        if let current = receipt {
                            receipt = try await files.stage(file: loaded.url, into: current, sourceKind: "photoImport")
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if let current = receipt {
                            receipt = try await files.recordFailure("Photo \(index + 1): " + safeMessage(error), in: current)
                        }
                    }
                }
                try Task.checkCancellation()
                await finishLoading(repository: repository)
            } catch is CancellationError {
                if let receipt { try? await files.discard(receipt) }
                receipt = nil
                showReview = false
            } catch { message = safeMessage(error) }
            busy = false
            progress = ""
            await refreshRecovery()
        }
    }

    func cancelLoading() { loadingTask?.cancel() }

    func resume(_ saved: IngestionReceipt, repository: JournalRepository) async {
        guard !busy else { return }
        var value = saved
        if value.phase == .loading {
            value.phase = .review
            value.failures.append("Loading was interrupted. Only the pages shown below were staged. Import any missing pages again.")
            do { try await files.persist(value) } catch { message = safeMessage(error); return }
        }
        receipt = value
        showReview = true
        await checkDuplicates(repository: repository)
    }

    func persistReview() async {
        guard let receipt, receipt.phase == .review else { return }
        do { try await files.persist(receipt) } catch { message = safeMessage(error) }
    }

    func discardReview() async {
        guard !busy, !saving, let receipt else { return }
        do {
            try await files.discard(receipt)
            self.receipt = nil
            showReview = false
            await refreshRecovery()
        } catch { message = safeMessage(error) }
    }

    func save(model: JournalAppModel) async {
        guard !saving, !busy, var current = receipt, let repository = model.repository else { return }
        guard !current.pages.isEmpty else { message = safeMessage(IngestionError.empty); return }
        guard current.failures.isEmpty || current.acknowledgedFailures else { message = safeMessage(IngestionError.incomplete); return }
        guard current.notebookID != nil else { message = safeMessage(IngestionError.notebook); return }
        saving = true
        defer { saving = false }
        do {
            current.phase = .saving
            try await files.persist(current) // Freeze IDs/order/metadata before the first database write.
            receipt = current
            let folder = await files.directory(current.id)
            let saved = await model.change { repository in
                try await repository.commit(current, directory: folder)
            }
            guard saved else {
                message = "Save could not finish. The receipt and staged pages are kept. Retry; if its notebook was deleted, restore that notebook first."
                return
            }
            // Derivatives are disposable; failure here must not imply the authoritative save failed.
            do { try await JournalImageCache.shared.adopt(current, directory: folder) }
            catch { message = "Pages were saved. Cached previews will be regenerated when opened." }
            try await files.finish(current) // Archives local ownership before releasing staged input.
            await model.ocr.ingestionSaved()
            if !preview { UserDefaults.standard.set(current.notebookID?.uuidString, forKey: "lastCaptureNotebook") }
            receipt = nil
            showReview = false
            await refreshRecovery()
            _ = repository
        } catch { message = safeMessage(error); await refreshRecovery() }
    }

    func scan(notebookID: UUID?) async {
        preferredNotebook = notebookID
        cameraDenied = false
        #if os(iOS)
        #if targetEnvironment(simulator)
        let supported = false
        #else
        let supported = VNDocumentCameraViewController.isSupported
        #endif
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let decision = CameraDecision.resolve(supported: supported, authorized: status == .authorized, notDetermined: status == .notDetermined)
        switch decision {
        case .unsupported:
            message = "Document scanning is unavailable on this device. Use Import Photos instead."
        case .denied:
            denyCamera()
        case .request:
            if await AVCaptureDevice.requestAccess(for: .video) { showScanner = true } else { denyCamera() }
        case .scan:
            showScanner = true
        }
        #else
        message = "Use Import Photos on this device. Document scanning requires a supported iPhone."
        #endif
    }

    #if os(iOS)
    func receivedScan(_ scan: VNDocumentCameraScan, repository: JournalRepository) {
        showScanner = false
        busy = true
        loadingTask = Task {
            do {
                receipt = try await files.begin(count: scan.pageCount, notebookID: preferredNotebook)
                showReview = true
                duplicates = []
                for index in 0..<scan.pageCount {
                    try Task.checkCancellation()
                    progress = "Staging scan \(index + 1) of \(scan.pageCount)"
                    do {
                        // VisionKit owns its results. Hold only one returned UIImage at a time.
                        let file = try autoreleasepool { () throws -> URL in
                            let image = scan.imageOfPage(at: index)
                            let width = Int(image.size.width * image.scale)
                            let height = Int(image.size.height * image.scale)
                            guard width > 0, height > 0, width <= 16_000, height <= 16_000,
                                  width * height <= ImportLimits.pixels,
                                  let data = image.jpegData(compressionQuality: 0.95) else { throw IngestionError.limit }
                            guard data.count <= ImportLimits.imageBytes else { throw IngestionError.limit }
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scan.jpg")
                            try data.write(to: url, options: .atomic)
                            return url
                        }
                        defer { try? FileManager.default.removeItem(at: file) }
                        if let current = receipt {
                            receipt = try await files.stage(file: file, into: current, sourceKind: "processedDocumentScan")
                        }
                    } catch {
                        if let current = receipt {
                            receipt = try await files.recordFailure("Scan page \(index + 1): " + safeMessage(error), in: current)
                        }
                    }
                }
                try Task.checkCancellation()
                await finishLoading(repository: repository)
            } catch is CancellationError {
                if let receipt { try? await files.discard(receipt) }
                receipt = nil
                showReview = false
            } catch { message = safeMessage(error) }
            busy = false
            progress = ""
            await refreshRecovery()
        }
    }
    #endif

    func scannerCancelled() { showScanner = false }
    func scannerFailed() {
        showScanner = false
        message = "The document scanner could not finish. No journal entry was created. Try again or use Import Photos."
    }

    private func denyCamera() {
        cameraDenied = true
        message = "Camera access is off or restricted. Use Import Photos, or enable Camera for Journalite in Settings if permitted."
    }

    private func finishLoading(repository: JournalRepository) async {
        if var current = receipt {
            current.phase = .review
            do { try await files.persist(current); receipt = current }
            catch { message = safeMessage(error) }
        }
        await checkDuplicates(repository: repository)
    }

    private func checkDuplicates(repository: JournalRepository) async {
        duplicates = []
        var hashes: Set<String> = []
        for page in receipt?.pages ?? [] {
            do {
                let existing = try await repository.containsSource(hash: page.hash)
                if existing || hashes.contains(page.hash) { duplicates.insert(page.id) }
                hashes.insert(page.hash)
            } catch { message = "Duplicate checking was unavailable. Review before saving; no pages have been discarded." }
        }
    }

    private func safeMessage(_ error: Error) -> String {
        (error as? IngestionError)?.errorDescription ?? "The selected item could not be loaded or staged. Check available storage or download it in Photos and try again."
    }
}
