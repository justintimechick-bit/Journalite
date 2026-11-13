import CoreData
import Foundation
import Observation

/// App-facing search state. Owns the derived index files, keeps them current after local saves
/// (and, later, remote imports) and answers queries. Journal text is never logged and never
/// donated to Spotlight.
@MainActor
@Observable
final class SearchCoordinator {
    enum Status: Equatable {
        case notConfigured
        case building
        case ready
        /// The index could not be opened or updated. Results may be stale; offer Rebuild.
        case failed
        /// FTS5 is missing from the platform SQLite; bounded Core Data fallback in use.
        case fallback
    }

    static let resultLimit = 50

    private(set) var status: Status = .notConfigured
    /// Incremented whenever the index changes, so visible results can refresh.
    private(set) var revision = 0

    private let directory: URL
    private var container: NSPersistentContainer?
    private var indexer: SearchIndexer?
    private var reader: SearchReader?
    private var fallback: FallbackSearcher?
    private var observer: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var updateRequested = false

    init(preview: Bool) {
        directory = preview
            ? FileManager.default.temporaryDirectory.appendingPathComponent("PreviewSearch-" + UUID().uuidString, isDirectory: true)
            : URL.applicationSupportDirectory.appendingPathComponent("Journalite/SearchIndex", isDirectory: true)
    }

    /// For tests: an isolated index directory.
    init(directory: URL) {
        self.directory = directory
    }

    var indexDirectory: URL { directory }

    func configure(container: NSPersistentContainer) async {
        guard self.container == nil else { return }
        self.container = container
        guard SearchDatabase.ftsAvailable() else {
            fallback = FallbackSearcher(container: container)
            status = .fallback
            return
        }
        do {
            try openIndex(container: container)
        } catch {
            // A damaged derived index is discarded and recreated; the journal is unaffected.
            SearchDatabase.destroyFiles(in: directory)
            do { try openIndex(container: container) } catch {
                status = .failed
                return
            }
        }
        observeStoreChanges(container: container)
        await requestUpdate()
    }

    /// Coalesces bursts of saves into serial catch-up passes. Every caller waits for a pass that
    /// started after its request, so a change is indexed by the time this returns.
    func requestUpdate() async {
        guard indexer != nil else { return }
        updateRequested = true
        if drainTask == nil {
            drainTask = Task {
                await drain()
                drainTask = nil
            }
        }
        await drainTask?.value
    }

    private func drain() async {
        while updateRequested, let indexer {
            updateRequested = false
            if await indexer.needsRebuild() { status = .building }
            do {
                try await indexer.catchUp()
                status = .ready
            } catch {
                status = .failed
            }
            revision += 1
        }
    }

    /// Settings action. Clears the derived index and rebuilds it from Core Data.
    func rebuild() async {
        guard let container else { return }
        if status == .fallback { return }
        status = .building
        do {
            if let indexer {
                try await indexer.rebuild()
            } else {
                throw SearchIndexError.ftsUnavailable
            }
        } catch {
            // Recreate the files and try once more; never touches the Core Data store.
            observer?.cancel()
            indexer = nil
            reader = nil
            SearchDatabase.destroyFiles(in: directory)
            do {
                try openIndex(container: container)
                observeStoreChanges(container: container)
                try await indexer?.rebuild()
            } catch {
                status = .failed
                revision += 1
                return
            }
        }
        status = .ready
        revision += 1
    }

    func search(_ text: String, filters: SearchFilters) async throws -> [SearchHit] {
        if let reader {
            return try await reader.search(text, filters: filters, limit: Self.resultLimit)
        }
        if let fallback {
            return try await fallback.search(text, filters: filters, limit: Self.resultLimit)
        }
        throw SearchIndexError.ftsUnavailable
    }

    private func openIndex(container: NSPersistentContainer) throws {
        try Self.prepare(directory)
        let url = directory.appendingPathComponent(SearchDatabase.fileName)
        let writer = try SearchDatabase(url: url)
        let readerConnection = try SearchDatabase(url: url)
        indexer = SearchIndexer(container: container, database: writer)
        reader = SearchReader(database: readerConnection)
    }

    /// Protected until first unlock (indexing can run after the device is unlocked once) and
    /// excluded from backup: the index is rebuilt from the journal, which is backed up.
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }

    /// Persistent-history remote-change notifications are posted for every save to the store,
    /// including background contexts in this process and future sync imports.
    private func observeStoreChanges(container: NSPersistentContainer) {
        observer?.cancel()
        let coordinator = container.persistentStoreCoordinator
        observer = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange, object: coordinator) {
                guard let self else { return }
                await self.requestUpdate()
            }
        }
    }
}
