import Foundation
import SQLite3

/// One indexed unit: a live page, or an entry that has no live pages (so its title stays searchable).
nonisolated struct SearchDocument: Sendable, Equatable {
    /// Page UUID string, or `entry:<UUID>` for an entry without live pages.
    let docID: String
    let pageID: UUID?
    let entryID: UUID
    let notebookID: UUID?
    /// 1-based position among the entry's live pages, matching the page navigator; 0 for entry rows.
    let pageNumber: Int
    let imageVersion: UUID?
    let journalDate: Date?
    let isFavorite: Bool
    let isReviewed: Bool
    /// Canonical user-visible text only: the selected manual revision (blank allowed) or raw OCR.
    let body: String
    let title: String
    let notebookName: String
}

nonisolated struct SearchHit: Identifiable, Sendable, Equatable {
    var id: String { docID }
    let docID: String
    let pageID: UUID?
    let entryID: UUID
    let notebookID: UUID?
    let pageNumber: Int
    let imageVersion: UUID?
    let journalDate: Date?
    let isFavorite: Bool
    let isReviewed: Bool
    /// Entry title with `SearchMarkup` emphasis.
    let title: String
    /// Short page-text excerpt with `SearchMarkup` emphasis; may be empty.
    let excerpt: String
    let notebookName: String
    /// Whether the page text itself matched (rather than only title or notebook name).
    let bodyMatched: Bool
}

nonisolated enum SearchIndexError: Error, Equatable {
    case open(Int32)
    case sql(Int32)
    case ftsUnavailable
}

/// A connection to the derived search index. This is a separate SQLite file owned by the app and
/// is never the Core Data store. Each instance is confined to one actor.
nonisolated final class SearchDatabase: @unchecked Sendable {
    static let schemaVersion = "1"
    static let fileName = "SearchIndex.sqlite"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?

    init(url: URL) throws {
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        #if os(iOS)
        // Applies to the database and its -wal/-shm sidecars.
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        #endif
        let status = sqlite3_open_v2(url.path, &db, flags, nil)
        guard status == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw SearchIndexError.open(status)
        }
        sqlite3_busy_timeout(db, 5_000)
        try exec("PRAGMA journal_mode=WAL")
        // Removed journal text is overwritten rather than left in free pages.
        try exec("PRAGMA secure_delete=ON")
        try createSchema()
    }

    deinit { sqlite3_close_v2(db) }

    /// Probes the platform SQLite library for FTS5 using a throwaway in-memory database.
    static func ftsAvailable() -> Bool {
        var probe: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &probe, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(probe)
            return false
        }
        defer { sqlite3_close(probe) }
        return sqlite3_exec(probe, "CREATE VIRTUAL TABLE probe USING fts5(body)", nil, nil, nil) == SQLITE_OK
    }

    /// Removes only the index file and its sidecars inside `directory`.
    static func destroyFiles(in directory: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName + suffix))
        }
    }

    private func createSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS docs(
                id INTEGER PRIMARY KEY,
                doc_id TEXT NOT NULL UNIQUE,
                page_id TEXT,
                entry_id TEXT NOT NULL,
                notebook_id TEXT,
                page_number INTEGER NOT NULL,
                image_version TEXT,
                journal_date REAL,
                is_favorite INTEGER NOT NULL,
                is_reviewed INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS docs_entry ON docs(entry_id);
            CREATE INDEX IF NOT EXISTS docs_notebook ON docs(notebook_id);
            """)
        let created = sqlite3_exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                body, title, notebook, tokenize = 'unicode61 remove_diacritics 2')
            """, nil, nil, nil)
        guard created == SQLITE_OK else { throw SearchIndexError.ftsUnavailable }
    }

    // MARK: Transactions and metadata

    /// Runs `body` in one write transaction. Nothing (including the history token) is kept on error.
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func meta(_ key: String) throws -> Data? {
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { statement in
            sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Self.blob(statement, 0)
        }.first ?? nil
    }

    func metaString(_ key: String) throws -> String? {
        try meta(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setMeta(_ key: String, _ value: Data?) throws {
        if let value {
            try run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [.text(key), .blob(value)])
        } else {
            try run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    func setMeta(_ key: String, string: String) throws {
        try setMeta(key, Data(string.utf8))
    }

    // MARK: Documents

    func deleteAll() throws {
        try exec("DELETE FROM fts; DELETE FROM docs;")
    }

    func deleteEntry(_ entryID: UUID) throws {
        let id = Binding.text(entryID.uuidString)
        try run("DELETE FROM fts WHERE rowid IN (SELECT id FROM docs WHERE entry_id = ?)", [id])
        try run("DELETE FROM docs WHERE entry_id = ?", [id])
    }

    /// Replaces every row of one entry. Replaying the same change is therefore idempotent.
    func replaceEntry(_ entryID: UUID, with documents: [SearchDocument]) throws {
        try deleteEntry(entryID)
        for document in documents { try insert(document) }
    }

    func insert(_ document: SearchDocument) throws {
        try run("""
            INSERT INTO docs(doc_id, page_id, entry_id, notebook_id, page_number, image_version,
                             journal_date, is_favorite, is_reviewed)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(document.docID), .optionalText(document.pageID?.uuidString), .text(document.entryID.uuidString),
                .optionalText(document.notebookID?.uuidString), .int(Int64(document.pageNumber)),
                .optionalText(document.imageVersion?.uuidString),
                document.journalDate.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                .int(document.isFavorite ? 1 : 0), .int(document.isReviewed ? 1 : 0),
            ])
        let rowID = sqlite3_last_insert_rowid(db)
        try run("INSERT INTO fts(rowid, body, title, notebook) VALUES(?, ?, ?, ?)",
                [.int(rowID), .text(document.body), .text(document.title), .text(document.notebookName)])
    }

    func indexedEntryIDs() throws -> Set<UUID> {
        Set(try query("SELECT DISTINCT entry_id FROM docs", []) { Self.uuid($0, 0) }.compactMap { $0 })
    }

    /// Stable IDs of indexed pages, used to clean up rows for pages that no longer exist.
    func indexedPages() throws -> [(pageID: UUID, entryID: UUID)] {
        try query("SELECT page_id, entry_id FROM docs WHERE page_id IS NOT NULL", []) { statement in
            guard let page = Self.uuid(statement, 0), let entry = Self.uuid(statement, 1) else { return nil }
            return (page, entry)
        }.compactMap { $0 }
    }

    func documentCount() throws -> Int {
        try query("SELECT COUNT(*) FROM docs", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    // MARK: Search

    /// `expression` must come from `SearchQuery.ftsExpression`; it is bound, never interpolated.
    func search(expression: String, filters: SearchFilters, limit: Int) throws -> [SearchHit] {
        let review: Binding
        switch filters.review {
        case .any: review = .null
        case .needsReview: review = .int(0)
        case .reviewed: review = .int(1)
        }
        let rows = try query("""
            SELECT d.doc_id, d.page_id, d.entry_id, d.notebook_id, d.page_number, d.image_version,
                   d.journal_date, d.is_favorite, d.is_reviewed,
                   highlight(fts, 1, char(1), char(2)),
                   snippet(fts, 0, char(1), char(2), '…', 14),
                   fts.notebook
            FROM fts JOIN docs d ON d.id = fts.rowid
            WHERE fts MATCH ?1
              AND (?2 IS NULL OR d.notebook_id = ?2)
              AND (?3 IS NULL OR d.journal_date >= ?3)
              AND (?4 IS NULL OR d.journal_date <= ?4)
              AND (?5 = 0 OR d.is_favorite = 1)
              AND (?6 IS NULL OR d.is_reviewed = ?6)
            ORDER BY bm25(fts, 1.0, 2.0, 0.5), d.journal_date DESC, d.doc_id
            LIMIT ?7
            """, [
                .text(expression),
                .optionalText(filters.notebookID?.uuidString),
                filters.dateFrom.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                filters.dateThrough.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                .int(filters.favoritesOnly ? 1 : 0),
                review,
                // Over-fetch: title-only matches collapse to one row per entry below.
                .int(Int64(limit * 4)),
            ]) { statement -> SearchHit? in
                guard let docID = Self.text(statement, 0), let entryID = Self.uuid(statement, 2) else { return nil }
                let excerpt = Self.text(statement, 10) ?? ""
                return SearchHit(
                    docID: docID,
                    pageID: Self.uuid(statement, 1),
                    entryID: entryID,
                    notebookID: Self.uuid(statement, 3),
                    pageNumber: Int(sqlite3_column_int64(statement, 4)),
                    imageVersion: Self.uuid(statement, 5),
                    journalDate: sqlite3_column_type(statement, 6) == SQLITE_NULL
                        ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                    isFavorite: sqlite3_column_int64(statement, 7) != 0,
                    isReviewed: sqlite3_column_int64(statement, 8) != 0,
                    title: Self.text(statement, 9) ?? "",
                    excerpt: excerpt,
                    notebookName: Self.text(statement, 11) ?? "",
                    bodyMatched: SearchMarkup.hasEmphasis(excerpt))
            }
        return SearchResultsAssembler.collapse(rows.compactMap { $0 }, limit: limit)
    }

    // MARK: SQLite plumbing

    enum Binding {
        case null, int(Int64), double(Double), text(String), blob(Data)
        static func optionalText(_ value: String?) -> Binding { value.map { .text($0) } ?? .null }
    }

    private func exec(_ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw SearchIndexError.sql(status) }
    }

    private func run(_ sql: String, _ bindings: [Binding]) throws {
        _ = try query(sql, bindings) { _ in () }
    }

    private func query<T>(_ sql: String, _ bindings: [Binding], row: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw SearchIndexError.sql(status) }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .null: status = sqlite3_bind_null(statement, index)
            case .int(let value): status = sqlite3_bind_int64(statement, index, value)
            case .double(let value): status = sqlite3_bind_double(statement, index, value)
            case .text(let value): status = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .blob(let value):
                status = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
            guard status == SQLITE_OK else { throw SearchIndexError.sql(status) }
        }
        var rows: [T] = []
        while true {
            status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                rows.append(row(statement))
            } else if status == SQLITE_DONE {
                return rows
            } else {
                throw SearchIndexError.sql(status)
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func uuid(_ statement: OpaquePointer, _ column: Int32) -> UUID? {
        text(statement, column).flatMap(UUID.init(uuidString:))
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// Shared by the FTS index and the fallback so both present results the same way.
nonisolated enum SearchResultsAssembler {
    /// Page-text matches are kept per page. When only the title or notebook name matched, an
    /// entry appears once, as its first page, instead of once per page. Order is preserved.
    static func collapse(_ hits: [SearchHit], limit: Int) -> [SearchHit] {
        // Entries whose page text matched are represented by those pages only.
        let entriesWithTextMatches = Set(hits.filter(\.bodyMatched).map(\.entryID))
        var titleOnlyIndex: [UUID: Int] = [:]
        var result: [SearchHit] = []
        for hit in hits {
            if hit.bodyMatched {
                result.append(hit)
            } else if entriesWithTextMatches.contains(hit.entryID) {
                continue
            } else if let index = titleOnlyIndex[hit.entryID] {
                if hit.pageNumber < result[index].pageNumber { result[index] = hit }
            } else {
                titleOnlyIndex[hit.entryID] = result.count
                result.append(hit)
            }
        }
        return Array(result.prefix(limit))
    }
}
