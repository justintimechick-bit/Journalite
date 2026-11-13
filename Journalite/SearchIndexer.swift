import CoreData
import Foundation

/// Builds search documents from Core Data, the authoritative store. Pure reads; never writes.
nonisolated enum SearchDocumentBuilder {
    /// Current documents for one entry. Empty when the entry should not appear in normal search:
    /// trashed, in a trashed notebook, or still part of an unfinished ingestion.
    static func documents(for entry: NSManagedObject, in context: NSManagedObjectContext) throws -> [SearchDocument] {
        guard entry.value(forKey: "deletedAt") == nil,
              entry.value(forKey: "pendingIngestionID") == nil,
              let entryID = entry.value(forKey: "id") as? UUID else { return [] }
        let notebook = entry.value(forKey: "notebook") as? NSManagedObject
        if let notebook, notebook.value(forKey: "deletedAt") != nil { return [] }

        let title = clean(entry.value(forKey: "title") as? String ?? "")
        let notebookName = clean(notebook?.value(forKey: "name") as? String ?? "")
        let notebookID = notebook?.value(forKey: "id") as? UUID
        let journalDate = entry.value(forKey: "journalDate") as? Date
        let isFavorite = entry.value(forKey: "isFavorite") as? Bool ?? false

        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
        request.predicate = NSPredicate(format: "entry == %@ AND deletedAt == nil", entry)
        request.relationshipKeyPathsForPrefetching = ["transcriptRevisions"]
        // Same order as the page navigator, so page numbers in results match what the reader sees.
        let pages = try context.fetch(request).sorted { lhs, rhs in
            let left = (lhs.value(forKey: "position") as? NSNumber)?.int64Value ?? 0
            let right = (rhs.value(forKey: "position") as? NSNumber)?.int64Value ?? 0
            if left != right { return left < right }
            return ((lhs.value(forKey: "id") as? UUID)?.uuidString ?? "") < ((rhs.value(forKey: "id") as? UUID)?.uuidString ?? "")
        }

        guard !pages.isEmpty else {
            return [SearchDocument(docID: "entry:" + entryID.uuidString, pageID: nil, entryID: entryID,
                notebookID: notebookID, pageNumber: 0, imageVersion: nil, journalDate: journalDate,
                isFavorite: isFavorite, isReviewed: false, body: "", title: title, notebookName: notebookName)]
        }

        return pages.enumerated().compactMap { offset, page in
            guard let pageID = page.value(forKey: "id") as? UUID else { return nil }
            let selected = page.value(forKey: "selectedTranscriptRevisionID") as? UUID
            let ocrResultID = page.value(forKey: "ocrResultID") as? UUID
            let revisions = (page.value(forKey: "transcriptRevisions") as? Set<NSManagedObject> ?? []).compactMap { object -> TranscriptRevisionSummary? in
                guard let id = object.value(forKey: "id") as? UUID,
                      let text = object.value(forKey: "text") as? String else { return nil }
                return TranscriptRevisionSummary(id: id, text: text, createdAt: object.value(forKey: "createdAt") as? Date ?? .distantPast,
                    baseRevisionID: nil, imageVersion: nil, isSelected: id == selected)
            }
            // Only the text the reader sees is indexed. Superseded revisions and raw OCR hidden by a
            // manual correction are excluded; a pending revision pointer indexes no text at all.
            let resolution = TranscriptSelectionLogic.resolveCanonicalText(
                selectedRevisionID: selected,
                rawOCRText: page.value(forKey: "rawOCRText") as? String,
                ocrResultID: ocrResultID,
                revisions: revisions)
            let isReviewed = TranscriptSelectionLogic.computeIsReviewed(
                selectedRevisionID: selected, ocrResultID: ocrResultID,
                reviewedRevisionID: page.value(forKey: "reviewedRevisionID") as? UUID)
            return SearchDocument(docID: pageID.uuidString, pageID: pageID, entryID: entryID,
                notebookID: notebookID, pageNumber: offset + 1,
                imageVersion: page.value(forKey: "imageVersion") as? UUID,
                journalDate: journalDate, isFavorite: isFavorite, isReviewed: isReviewed,
                body: clean(resolution.displayText ?? ""), title: title, notebookName: notebookName)
        }
    }

    /// Emphasis markers must never come from journal text.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: SearchMarkup.open, with: " ")
            .replacingOccurrences(of: SearchMarkup.close, with: " ")
    }
}

/// Keeps the derived FTS index in step with Core Data by consuming persistent history serially.
/// Every batch of index changes and the history token that produced it commit in one SQLite
/// transaction, so a crash leaves either both or neither, and replay is idempotent because each
/// affected entry is fully replaced from current Core Data state.
actor SearchIndexer {
    enum IndexerError: Error { case noStore, simulatedCrash }

    private enum Key {
        static let schema = "schema"
        static let store = "storeIdentifier"
        static let token = "historyToken"
    }

    private struct HistoryBatch: Sendable {
        var entryIDs: Set<UUID> = []
        var notebookIDs: Set<UUID> = []
        var needsSweep = false
        /// Archived token of the batch's last transaction.
        var lastTokenData: Data?
    }

    private let container: NSPersistentContainer
    private let database: SearchDatabase
    private let transactionsPerCommit: Int
    private var tail: Task<Void, Never>?
    /// Test hook: fail after writing index rows but before COMMIT, as a crash would.
    private var failBeforeCommit = false

    init(container: NSPersistentContainer, database: SearchDatabase, transactionsPerCommit: Int = 100) {
        self.container = container
        self.database = database
        self.transactionsPerCommit = transactionsPerCommit
    }

    func setFailBeforeCommit(_ value: Bool) { failBeforeCommit = value }

    /// True when the index has never been built for this store or must be rebuilt.
    func needsRebuild() -> Bool {
        guard let store = try? storeInfo(), store.supportsHistory else { return true }
        return (try? validToken(for: store)) == nil
    }

    /// Applies outstanding history. Rebuilds instead when the token is missing, unreadable,
    /// expired, from another store, or from an older index schema. Returns true if it rebuilt.
    @discardableResult
    func catchUp() async throws -> Bool {
        try await serialized { try await self.performCatchUp() }
    }

    func rebuild() async throws {
        _ = try await serialized { try await self.performRebuild(); return true }
    }

    /// Runs operations one at a time even though the actor is reentrant across awaits.
    private func serialized(_ operation: @escaping @Sendable () async throws -> Bool) async throws -> Bool {
        let previous = tail
        let task = Task { () async throws -> Bool in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Catch-up

    private func performCatchUp() async throws -> Bool {
        let store = try storeInfo()
        guard store.supportsHistory, let token = try validToken(for: store) else {
            try await performRebuild()
            return true
        }
        let batches: [HistoryBatch]
        do {
            batches = try await historyBatches(after: token)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSPersistentHistoryTokenExpiredError {
            try await performRebuild()
            return true
        }
        for batch in batches {
            guard let tokenData = batch.lastTokenData else { continue }
            let entryIDs = try await entryIDs(for: batch)
            var documents = try await documents(forEntries: entryIDs)
            // Operations are serialized, so the index cannot change between planning and writing.
            var removals: Set<UUID> = []
            if batch.needsSweep {
                let stale = try staleEntries(live: try await liveIdentifiers())
                removals = stale.remove
                documents.merge(try await self.documents(forEntries: stale.reindex)) { current, _ in current }
            }
            try database.transaction {
                for entryID in removals { try database.deleteEntry(entryID) }
                for (entryID, docs) in documents { try database.replaceEntry(entryID, with: docs) }
                if failBeforeCommit { throw IndexerError.simulatedCrash }
                // Written in the same transaction: durable only if the index rows above commit.
                try database.setMeta(Key.token, tokenData)
            }
        }
        return false
    }

    /// History after `token`, fetched and mapped to affected entries inside one context so no
    /// history objects leave it. Each batch is later committed with its own last token.
    private func historyBatches(after token: NSPersistentHistoryToken) async throws -> [HistoryBatch] {
        let context = container.newBackgroundContext()
        let size = transactionsPerCommit
        return try await context.perform {
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
            request.resultType = .transactionsAndChanges
            let result = try context.execute(request) as? NSPersistentHistoryResult
            let all = result?.result as? [NSPersistentHistoryTransaction] ?? []
            return try stride(from: 0, to: all.count, by: size).map { start in
                try Self.summarize(all[start..<min(start + size, all.count)], in: context)
            }
        }
    }

    /// Maps changed objects to the entries whose documents must be replaced.
    private nonisolated static func summarize(_ transactions: ArraySlice<NSPersistentHistoryTransaction>,
                                              in context: NSManagedObjectContext) throws -> HistoryBatch {
        var batch = HistoryBatch()
        for transaction in transactions {
            for change in transaction.changes ?? [] {
                let entity = change.changedObjectID.entity.name ?? ""
                guard ["JournalEntry", "JournalPage", "TranscriptRevision", "Notebook"].contains(entity) else { continue }
                guard change.changeType != .delete,
                      let object = try? context.existingObject(with: change.changedObjectID) else {
                    // Deleted objects are gone from Core Data; the sweep uses the index's stored IDs.
                    batch.needsSweep = true
                    continue
                }
                switch entity {
                case "JournalEntry":
                    if let id = object.value(forKey: "id") as? UUID { batch.entryIDs.insert(id) }
                case "JournalPage":
                    if let id = (object.value(forKey: "entry") as? NSManagedObject)?.value(forKey: "id") as? UUID {
                        batch.entryIDs.insert(id)
                    } else { batch.needsSweep = true }
                case "TranscriptRevision":
                    let entry = (object.value(forKey: "page") as? NSManagedObject)?.value(forKey: "entry") as? NSManagedObject
                    if let id = entry?.value(forKey: "id") as? UUID { batch.entryIDs.insert(id) }
                case "Notebook":
                    if let id = object.value(forKey: "id") as? UUID { batch.notebookIDs.insert(id) }
                default:
                    break
                }
            }
        }
        if let last = transactions.last?.token {
            batch.lastTokenData = try NSKeyedArchiver.archivedData(withRootObject: last, requiringSecureCoding: true)
        }
        context.reset()
        return batch
    }

    /// Notebook renames, trash and restore affect every entry in the notebook.
    private func entryIDs(for batch: HistoryBatch) async throws -> Set<UUID> {
        guard !batch.notebookIDs.isEmpty else { return batch.entryIDs }
        let context = container.newBackgroundContext()
        let notebookIDs = Array(batch.notebookIDs)
        let fromStore: Set<UUID> = try await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "JournalEntry")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            request.predicate = NSPredicate(format: "notebook.id IN %@", notebookIDs)
            return Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
        }
        return batch.entryIDs.union(fromStore)
    }

    // MARK: Rebuild

    private func performRebuild() async throws {
        let store = try storeInfo()
        // Captured before reading, so writes made during the rebuild are replayed afterwards.
        let token = store.supportsHistory
            ? container.persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: [store.store])
            : nil
        let tokenData = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        let documents = try await allDocuments()
        try database.transaction {
            try database.deleteAll()
            for docs in documents.values {
                for document in docs { try database.insert(document) }
            }
            if failBeforeCommit { throw IndexerError.simulatedCrash }
            try database.setMeta(Key.schema, string: SearchDatabase.schemaVersion)
            try database.setMeta(Key.store, string: store.identifier)
            try database.setMeta(Key.token, tokenData)
        }
    }

    // MARK: Core Data reads

    private func documents(forEntries ids: Set<UUID>) async throws -> [UUID: [SearchDocument]] {
        guard !ids.isEmpty else { return [:] }
        let context = container.newBackgroundContext()
        let list = Array(ids)
        return try await context.perform {
            var result: [UUID: [SearchDocument]] = Dictionary(uniqueKeysWithValues: list.map { ($0, []) })
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalEntry")
            request.predicate = NSPredicate(format: "id IN %@", list)
            for entry in try context.fetch(request) {
                guard let id = entry.value(forKey: "id") as? UUID else { continue }
                result[id] = try SearchDocumentBuilder.documents(for: entry, in: context)
            }
            context.reset()
            return result
        }
    }

    private func allDocuments() async throws -> [UUID: [SearchDocument]] {
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalEntry")
            request.predicate = NSPredicate(format: "deletedAt == nil AND pendingIngestionID == nil")
            request.fetchBatchSize = 100
            var result: [UUID: [SearchDocument]] = [:]
            for (offset, entry) in try context.fetch(request).enumerated() {
                guard let id = entry.value(forKey: "id") as? UUID else { continue }
                result[id] = try SearchDocumentBuilder.documents(for: entry, in: context)
                // Keep memory bounded on large journals; documents are plain values.
                if offset % 200 == 199 { context.refreshAllObjects() }
            }
            return result
        }
    }

    private struct LiveIdentifiers: Sendable {
        let entries: Set<UUID>
        let pages: Set<UUID>
    }

    private func liveIdentifiers() async throws -> LiveIdentifiers {
        let context = container.newBackgroundContext()
        return try await context.perform {
            func ids(_ entity: String) throws -> Set<UUID> {
                let request = NSFetchRequest<NSDictionary>(entityName: entity)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["id"]
                return Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
            }
            return LiveIdentifiers(entries: try ids("JournalEntry"), pages: try ids("JournalPage"))
        }
    }

    /// Indexed entries that no longer exist are removed; entries with an indexed page that no
    /// longer exists are rebuilt.
    private func staleEntries(live: LiveIdentifiers) throws -> (remove: Set<UUID>, reindex: Set<UUID>) {
        let remove = try database.indexedEntryIDs().subtracting(live.entries)
        let reindex = Set(try database.indexedPages().filter { !live.pages.contains($0.pageID) }.map(\.entryID))
            .subtracting(remove)
        return (remove, reindex)
    }

    // MARK: Store identity

    private struct StoreInfo {
        let store: NSPersistentStore
        let identifier: String
        let supportsHistory: Bool
    }

    private func storeInfo() throws -> StoreInfo {
        guard let store = container.persistentStoreCoordinator.persistentStores.first else { throw IndexerError.noStore }
        let tracked = (store.options?[NSPersistentHistoryTrackingKey] as? NSNumber)?.boolValue ?? false
        return StoreInfo(store: store, identifier: store.identifier ?? "",
                         supportsHistory: store.type == NSSQLiteStoreType && tracked)
    }

    /// The saved token, if it belongs to this store and this index schema.
    private func validToken(for store: StoreInfo) throws -> NSPersistentHistoryToken? {
        guard try database.metaString(Key.schema) == SearchDatabase.schemaVersion,
              try database.metaString(Key.store) == store.identifier,
              let data = try database.meta(Key.token) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    // MARK: Test support

    func storedToken() throws -> Data? { try database.meta(Key.token) }
    func overwriteStoredToken(_ data: Data?) throws { try database.setMeta(Key.token, data) }
    func overwriteStoreIdentifier(_ value: String) throws { try database.setMeta(Key.store, string: value) }
}

/// Read-only search against the index over its own connection, so typing never waits on indexing.
actor SearchReader {
    private let database: SearchDatabase

    init(database: SearchDatabase) { self.database = database }

    func search(_ text: String, filters: SearchFilters, limit: Int) throws -> [SearchHit] {
        guard let expression = SearchQuery.ftsExpression(from: text) else { return [] }
        return try database.search(expression: expression, filters: filters, limit: limit)
    }
}

/// Used only if the platform SQLite lacks FTS5. Scans at most `entryLimit` of the most recently
/// dated live entries straight from Core Data, so older entries can be missed. Documented as a
/// limitation; it is not a scalable index.
actor FallbackSearcher {
    static let entryLimit = 500
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) { self.container = container }

    func search(_ text: String, filters: SearchFilters, limit: Int) async throws -> [SearchHit] {
        let terms = SearchQuery.terms(from: text)
        guard !terms.isEmpty else { return [] }
        let context = container.newBackgroundContext()
        let hits: [SearchHit] = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalEntry")
            var predicates = [NSPredicate(format: "deletedAt == nil AND pendingIngestionID == nil")]
            if let notebookID = filters.notebookID { predicates.append(NSPredicate(format: "notebook.id == %@", notebookID as NSUUID)) }
            if let from = filters.dateFrom { predicates.append(NSPredicate(format: "journalDate >= %@", from as NSDate)) }
            if let through = filters.dateThrough { predicates.append(NSPredicate(format: "journalDate <= %@", through as NSDate)) }
            if filters.favoritesOnly { predicates.append(NSPredicate(format: "isFavorite == YES")) }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "journalDate", ascending: false), NSSortDescriptor(key: "id", ascending: true)]
            request.fetchLimit = Self.entryLimit
            var hits: [SearchHit] = []
            for entry in try context.fetch(request) {
                for document in try SearchDocumentBuilder.documents(for: entry, in: context) {
                    switch filters.review {
                    case .any: break
                    case .needsReview: if document.isReviewed { continue }
                    case .reviewed: if !document.isReviewed { continue }
                    }
                    let combined = [document.body, document.title, document.notebookName].joined(separator: "\n")
                    guard SearchQuery.matches(combined, terms: terms) else { continue }
                    let bodyMatched = !SearchQuery.emphasisRanges(in: document.body, terms: terms).isEmpty
                    hits.append(SearchHit(docID: document.docID, pageID: document.pageID, entryID: document.entryID,
                        notebookID: document.notebookID, pageNumber: document.pageNumber, imageVersion: document.imageVersion,
                        journalDate: document.journalDate, isFavorite: document.isFavorite, isReviewed: document.isReviewed,
                        title: SearchQuery.excerpt(from: document.title, terms: terms, radius: 200),
                        excerpt: bodyMatched ? SearchQuery.excerpt(from: document.body, terms: terms) : String(document.body.prefix(120)),
                        notebookName: document.notebookName, bodyMatched: bodyMatched))
                }
            }
            return hits
        }
        return SearchResultsAssembler.collapse(hits, limit: limit)
    }
}
