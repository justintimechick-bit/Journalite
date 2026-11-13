import Foundation
import Observation

@MainActor
@Observable
final class OCRCoordinator {
    private(set) var revision = 0
    private(set) var jobs: [OCRJob] = []
    private(set) var languages: [String] = []
    var language: String {
        didSet {
            if !preview { UserDefaults.standard.set(language, forKey: "ocrRecognitionLanguage") }
        }
    }
    var message: String?
    private let preview: Bool
    private let queue: OCRQueue
    private let service: OCRService
    private var worker: Task<Void, Never>?
    private var repository: JournalRepository?
    private var files: IngestionFiles?
    private var active = false
    private var wakeRequested = false

    init(preview: Bool) {
        self.preview = preview
        language = preview ? "en-US" : UserDefaults.standard.string(forKey: "ocrRecognitionLanguage") ?? "en-US"
        let root = preview
            ? FileManager.default.temporaryDirectory.appendingPathComponent("PreviewOCR-" + UUID().uuidString)
            : URL.applicationSupportDirectory.appendingPathComponent("Journalite/LocalOCR")
        let queue = OCRQueue(url: root.appendingPathComponent("queue.json"))
        self.queue = queue
        service = OCRService(queue: queue, scratch: root.appendingPathComponent("Scratch"))
    }

    func configure(repository: JournalRepository, files: IngestionFiles) async {
        self.repository = repository
        self.files = files
        do {
            message = nil
            languages = try await VisionOCRRecognizer.supportedLanguages()
            try await queue.load()
            try await service.reconcile(files: files, repository: repository, language: language)
            await refresh()
            kick()
        } catch { reportFailure() }
    }

    func setActive(_ value: Bool) {
        active = value
        if value { kick() } else { worker?.cancel() }
    }

    /// Call after ingestion is committed and its local ownership receipt is durable.
    func ingestionSaved() async {
        guard let repository, let files else { return }
        do {
            try await service.reconcile(files: files, repository: repository, language: language)
            await refresh()
            kick()
        } catch { reportFailure() }
    }

    func retry(pageID: UUID) async {
        guard let repository else { return }
        do {
            guard languages.contains(language),
                  let page = try await repository.ocrPage(id: pageID) else { throw OCRError.unavailable }
            try await queue.enqueue([page.key], language: language, retry: true)
            await refresh()
            kick()
        } catch { reportFailure() }
    }

    func cancel(_ key: OCRPageKey) async {
        do {
            try await queue.cancel(key)
            worker?.cancel()
            wakeRequested = active
            await refresh()
        } catch { reportFailure() }
    }

    func retryRecovery() async {
        guard let repository, let files else { return }
        message = nil
        await configure(repository: repository, files: files)
    }

    private func kick() {
        guard active, !preview, let repository else { return }
        if worker != nil { wakeRequested = true; return }
        wakeRequested = false
        worker = Task {
            do {
                try await service.run(repository: repository) { [weak self] in
                    await self?.refresh()
                }
            } catch { reportFailure() }
            worker = nil
            if wakeRequested && active { kick() }
        }
    }

    private func refresh() async {
        do { jobs = try await queue.snapshot(); revision += 1 }
        catch { reportFailure() }
    }

    private func reportFailure() {
        message = "Transcription could not continue. Your photos and corrections are safe. Check free storage, then retry. Queue files have been kept."
    }
}
