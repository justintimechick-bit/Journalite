import Foundation
import Observation

@MainActor
@Observable
final class JournalAppModel {
    enum Status { case idle, loading, ready, failed }

    private(set) var status: Status = .idle
    private(set) var notebooks: [NotebookSummary] = []
    private(set) var recentEntries: [EntrySummary] = []
    private(set) var repository: JournalRepository?
    private(set) var revision = 0
    private(set) var isSaving = false
    var operationError = false
    private(set) var hasStarted: Bool
    let capture: CaptureCoordinator
    let ocr: OCRCoordinator
    let isPreview: Bool
    private let persistence: PersistenceController

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        capture = CaptureCoordinator(preview: isPreview)
        ocr = OCRCoordinator(preview: isPreview)
        hasStarted = isPreview ? false : UserDefaults.standard.bool(forKey: "hasStartedLocalJournal")
        persistence = PersistenceController(location: isPreview ? .memory : .application)
    }

    func load() async {
        guard status != .loading, status != .ready else { return }
        status = .loading
        do {
            try await persistence.load()
            repository = try persistence.repository()
            try await refresh()
            status = .ready
            await capture.refreshRecovery()
            if let repository { await ocr.configure(repository: repository, files: capture.files) }
        } catch {
            status = .failed
        }
    }

    func refresh() async throws {
        guard let repository else { throw PersistenceError.notLoaded }
        notebooks = try await repository.notebooks()
        recentEntries = try await repository.entries(limit: 10).entries
    }

    /// Serialize UI writes and refresh every visible list after a committed mutation.
    func change(_ action: (JournalRepository) async throws -> Void) async -> Bool {
        guard !isSaving, let repository else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await action(repository)
        } catch {
            operationError = true
            return false
        }
        revision += 1
        do { try await refresh() } catch { operationError = true }
        return true
    }

    func start(names: [String]) async {
        if await change({ try await $0.createStarterNotebooks(names: names) }) {
            hasStarted = true
            if !isPreview { UserDefaults.standard.set(true, forKey: "hasStartedLocalJournal") }
        }
    }
}
