import CoreData
import Foundation
import Testing
@testable import Journalite

/// Each fixture owns a temporary on-disk Core Data store (with persistent history) and a
/// separate temporary index directory. No real journal data is used.
@MainActor
private final class SearchFixture {
    let folder: URL
    let storeURL: URL
    let indexDirectory: URL
    var store: PersistenceController
    var repository: JournalRepository
    var indexer: SearchIndexer
    var reader: SearchReader

    init() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SearchTests-" + UUID().uuidString)
        indexDirectory = folder.appendingPathComponent("SearchIndex", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        storeURL = folder.appendingPathComponent("Journal.sqlite")
        store = PersistenceController(location: .sqlite(storeURL))
        try await store.load()
        repository = try store.repository()
        let index = try Self.openIndex(container: try #require(store.container), directory: indexDirectory)
        indexer = index.0
        reader = index.1
    }

    static func openIndex(container: NSPersistentContainer, directory: URL) throws -> (SearchIndexer, SearchReader) {
        try SearchCoordinator.prepare(directory)
        let url = directory.appendingPathComponent(SearchDatabase.fileName)
        return (SearchIndexer(container: container, database: try SearchDatabase(url: url)),
                SearchReader(database: try SearchDatabase(url: url)))
    }

    func reopenIndex() throws {
        let index = try Self.openIndex(container: try #require(store.container), directory: indexDirectory)
        indexer = index.0
        reader = index.1
    }

    func close() {
        try? store.close()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Catches up, then searches.
    func search(_ text: String, _ filters: SearchFilters = SearchFilters()) async throws -> [SearchHit] {
        try await indexer.catchUp()
        return try await reader.search(text, filters: filters, limit: 50)
    }

    func notebook(_ name: String) async throws -> UUID {
        try await repository.createNotebook(name: name)
    }

    func entry(_ title: String, in notebook: UUID, pages: Int = 1, date: Date = Date()) async throws -> (entry: UUID, pages: [UUID]) {
        let drafts = (0..<pages).map { index in
            PageDraft(sourceData: Data([UInt8(index), 1, 2, 3]), contentType: "public.jpeg",
                      pixelWidth: 10, pixelHeight: 10, sourceKind: "photoImport", sourceHash: nil)
        }
        let entryID = try await repository.createEntry(notebookID: notebook, title: title, journalDate: date, pages: drafts)
        return (entryID, try await repository.pages(entryID: entryID).map(\.id))
    }

    func ocr(_ pageID: UUID, _ text: String) async throws {
        let snapshot = try #require(try await repository.ocrPage(id: pageID))
        let job = OCRJob(key: snapshot.key, resultID: UUID(), language: "en-US", state: .running)
        #expect(try await repository.saveOCR(OCRResult(text: text, revision: 3, language: "en-US", lowConfidenceLineCount: 0), job: job))
    }
}

@MainActor
struct SearchTests {
    // MARK: Environment

    @Test func platformSQLiteProvidesFTS5() {
        // Recorded so a missing FTS5 is noticed rather than silently relying on the fallback.
        #expect(SearchDatabase.ftsAvailable())
    }

    @Test func indexIsASeparateExcludedFileAndRemovingItKeepsTheJournal() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        _ = try await f.entry("Kept entry", in: notebook)
        _ = try await f.search("kept")
        let indexFile = f.indexDirectory.appendingPathComponent(SearchDatabase.fileName)
        #expect(indexFile.standardizedFileURL != f.storeURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: indexFile.path))
        #expect(try f.indexDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // Deleting the derived index loses nothing: it is rebuilt from Core Data.
        SearchDatabase.destroyFiles(in: f.indexDirectory)
        #expect(FileManager.default.fileExists(atPath: f.storeURL.path))
        try f.reopenIndex()
        #expect(try await f.indexer.catchUp())
        #expect(try await f.search("kept").count == 1)
    }

    // MARK: Query builder

    @Test func queryBuilderNeutralizesFTSSyntax() async throws {
        #expect(SearchQuery.ftsExpression(from: "John 3:16") == #""john"* "3 16"*"#)
        #expect(SearchQuery.ftsExpression(from: "“Psalm 23”") == #""psalm 23""#)
        #expect(SearchQuery.ftsExpression(from: "\"still typing") == #""still typing""#)
        #expect(SearchQuery.ftsExpression(from: "Pray OR NOT") == #""pray"* "or"* "not"*"#)
        #expect(SearchQuery.ftsExpression(from: "  ...  ;; ") == nil)
        #expect(SearchQuery.ftsExpression(from: "") == nil)
        #expect(SearchQuery.terms(from: String(repeating: "word ", count: 40)).count == SearchQuery.maxTerms)

        // Hostile input must run as plain words without SQL or FTS errors.
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        let page = try await f.entry("Title", in: notebook).pages[0]
        try await f.ocr(page, "near the title secret star")
        for input in ["NEAR(a b)", "title:secret", "body : x", "a OR b", "*", "^start", "\"", "'); DROP TABLE docs;--",
                      "-secret", "{body}", "AND", "NOT secret", "s*cret", "\u{1}x\u{2}", "😀 joy"] {
            _ = try await f.search(input)
        }
        #expect(try await f.search("title:secret").map(\.pageID) == [page])
        #expect(try await f.search("NOT secret").isEmpty) // "not" is just a word that isn't present
        #expect(try await f.search("'); DROP TABLE docs;--").isEmpty)
        #expect(try await f.search("secret").count == 1)
    }

    // MARK: Canonical text

    @Test func correctedTextReplacesRawOCRAndBlankCorrectionsHideIt() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        let (_, pages) = try await f.entry("Lake trip", in: notebook, pages: 2)
        try await f.ocr(pages[0], "Jhon went fishing at dawn")
        try await f.ocr(pages[1], "noisy smudge recognized")

        #expect(try await f.search("jhon").map(\.pageID) == [pages[0]])

        _ = try await f.repository.appendCorrection(pageID: pages[0], text: "John went fishing at dawn")
        #expect(try await f.search("jhon").isEmpty) // superseded raw OCR is not searchable
        #expect(try await f.search("john").map(\.pageID) == [pages[0]])

        // A later correction supersedes the earlier one.
        _ = try await f.repository.appendCorrection(pageID: pages[0], text: "Johnny went fishing")
        #expect(try await f.search("dawn").isEmpty)
        #expect(try await f.search("johnny").map(\.pageID) == [pages[0]])

        // Blank correction: valid content, hides OCR, the title still finds the entry.
        _ = try await f.repository.appendCorrection(pageID: pages[1], text: "")
        #expect(try await f.search("smudge").isEmpty)
        let titleHits = try await f.search("lake")
        #expect(titleHits.count == 1)
        #expect(titleHits.first?.bodyMatched == false)
        #expect(titleHits.first?.pageNumber == 1)

        // Explicit retry makes OCR current again and searchable.
        let snapshot = try #require(try await f.repository.ocrPage(id: pages[1]))
        var retry = OCRJob(key: snapshot.key, resultID: UUID(), language: "en-US", state: .running)
        retry.selectsResult = true
        _ = try await f.repository.saveOCR(OCRResult(text: "clear heron sighting", revision: 3, language: "en-US", lowConfidenceLineCount: 0), job: retry)
        #expect(try await f.search("heron").map(\.pageID) == [pages[1]])
    }

    @Test func punctuationCaseDiacriticsPhrasesAndPrefixes() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        let verse = try await f.entry("Sunday", in: notebook).pages[0]
        let apart = try await f.entry("Monday", in: notebook).pages[0]
        try await f.ocr(verse, "John 3:16 — Grandma Ruthie's café. Don't worry!")
        try await f.ocr(apart, "chapter 3 had 16 verses")

        #expect(try await f.search("john 3:16").map(\.pageID) == [verse])
        #expect(try await f.search("3:16").map(\.pageID) == [verse]) // adjacent, not merely both numbers
        #expect(try await f.search("JOHN").map(\.pageID) == [verse])
        #expect(try await f.search("cafe").map(\.pageID) == [verse])
        #expect(try await f.search("Café").map(\.pageID) == [verse])
        #expect(try await f.search("ruthie's").map(\.pageID) == [verse])
        #expect(try await f.search("don't").map(\.pageID) == [verse])
        #expect(try await f.search("grand").map(\.pageID) == [verse]) // word prefix
        #expect(try await f.search("andma").isEmpty) // not substring search
        #expect(try await f.search("\"grandma ruthie\"").map(\.pageID) == [verse])
        #expect(try await f.search("\"ruthie grandma\"").isEmpty)
        #expect(try await f.search("\"gran\"").isEmpty) // quoted phrases are exact, not prefixes
        #expect(Set(try await f.search("16").compactMap(\.pageID)) == [verse, apart])

        let hit = try #require(try await f.search("worry").first)
        #expect(SearchMarkup.hasEmphasis(hit.excerpt))
        #expect(SearchMarkup.plain(hit.excerpt).contains("worry"))
        #expect(!SearchMarkup.plain(hit.excerpt).contains(SearchMarkup.open))
    }

    @Test func titleOnlyEntriesAreSearchable() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Letters")
        let pageless = try await f.entry("Letters to Dad", in: notebook, pages: 0)
        let untranscribed = try await f.entry("Garden notes", in: notebook, pages: 3)

        let dad = try await f.search("dad")
        #expect(dad.map(\.entryID) == [pageless.entry])
        #expect(dad.first?.pageID == nil)

        // One result per entry for a title match, opening the first page.
        let garden = try await f.search("garden")
        #expect(garden.count == 1)
        #expect(garden.first?.pageID == untranscribed.pages[0])

        // Notebook names are searchable too.
        #expect(Set(try await f.search("letters").map(\.entryID)) == [pageless.entry, untranscribed.entry])
    }

    // MARK: Changes

    @Test func notebookRenameAndEntryMoveUpdateResults() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let bible = try await f.notebook("Bible Notes")
        let family = try await f.notebook("Family")
        let (entry, pages) = try await f.entry("Week one", in: bible)
        try await f.ocr(pages[0], "mercy every morning")

        #expect(try await f.search("bible").map(\.entryID) == [entry])
        try await f.repository.updateNotebook(id: bible, name: "Scripture", colorToken: "ink", symbolName: "book.closed")
        #expect(try await f.search("bible").isEmpty)
        #expect(try await f.search("scripture").first?.notebookName == "Scripture")

        try await f.repository.updateEntry(id: entry, title: "Week one", journalDate: Date(), isFavorite: false, notebookID: family)
        let moved = try #require(try await f.search("mercy").first)
        #expect(moved.notebookID == family)
        #expect(try await f.search("mercy", SearchFilters(notebookID: bible)).isEmpty)
        #expect(try await f.search("mercy", SearchFilters(notebookID: family)).count == 1)
    }

    @Test func trashRestoreRemovePagesAndPermanentDeletion() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        let other = try await f.notebook("Other")
        let (entry, pages) = try await f.entry("Harvest", in: notebook, pages: 2)
        try await f.ocr(pages[0], "apples gathered")
        try await f.ocr(pages[1], "pears gathered")
        #expect(try await f.search("gathered").count == 2)

        try await f.repository.trashEntry(id: entry)
        #expect(try await f.search("gathered").isEmpty)
        #expect(try await f.search("harvest").isEmpty)
        try await f.repository.restoreEntry(id: entry)
        #expect(try await f.search("gathered").count == 2)

        try await f.repository.trashNotebook(id: notebook)
        #expect(try await f.search("apples").isEmpty)
        try await f.repository.restoreNotebook(id: notebook)
        #expect(try await f.search("apples").count == 1)

        try await f.repository.removePage(id: pages[0])
        #expect(try await f.search("apples").isEmpty)
        #expect(try await f.search("pears").first?.pageNumber == 1) // renumbered like the navigator
        try await f.repository.restorePage(id: pages[0])
        #expect(try await f.search("apples").first?.pageNumber == 2)

        // Permanent deletion leaves no index rows behind (cleaned up by stored IDs).
        let (doomed, doomedPages) = try await f.entry("Doomed", in: other)
        try await f.ocr(doomedPages[0], "temporary words")
        #expect(try await f.search("temporary").count == 1)
        try await f.repository.trashEntry(id: doomed)
        try await f.repository.permanentlyDelete(id: doomed, notebook: false)
        try await f.indexer.catchUp()
        #expect(try await f.search("temporary").isEmpty)
        try await f.repository.trashNotebook(id: other)
        try await f.repository.permanentlyDelete(id: other, notebook: true)
        #expect(try await f.search("other").isEmpty)
        #expect(try await f.search("gathered").count == 2)
    }

    @Test func filtersForNotebookDateFavoriteAndReview() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let a = try await f.notebook("A")
        let b = try await f.notebook("B")
        let early = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let late = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = try await f.entry("First", in: a, date: early)
        let second = try await f.entry("Second", in: b, date: late)
        try await f.ocr(first.pages[0], "shared word")
        try await f.ocr(second.pages[0], "shared word")
        try await f.repository.updateEntry(id: second.entry, title: "Second", journalDate: late, isFavorite: true, notebookID: b)
        try await f.repository.markPageReviewed(pageID: first.pages[0], reviewed: true)

        #expect(try await f.search("shared").count == 2) // All Notebooks by default
        #expect(try await f.search("shared", SearchFilters(notebookID: a)).map(\.entryID) == [first.entry])
        #expect(try await f.search("shared", SearchFilters(favoritesOnly: true)).map(\.entryID) == [second.entry])
        #expect(try await f.search("shared", SearchFilters(review: .reviewed)).map(\.entryID) == [first.entry])
        #expect(try await f.search("shared", SearchFilters(review: .needsReview)).map(\.entryID) == [second.entry])
        #expect(try await f.search("shared", SearchFilters(dateFrom: late.addingTimeInterval(-60))).map(\.entryID) == [second.entry])
        #expect(try await f.search("shared", SearchFilters(dateThrough: early.addingTimeInterval(60))).map(\.entryID) == [first.entry])

        // Editing the reviewed text returns it to Needs review in search too.
        _ = try await f.repository.appendCorrection(pageID: first.pages[0], text: "shared word, edited")
        #expect(try await f.search("shared", SearchFilters(review: .reviewed)).isEmpty)
    }

    // MARK: Rebuild and history replay

    @Test func rebuildProducesTheSameResultsAsIncrementalUpdates() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        var expectations: [(String, Int)] = []
        for index in 0..<6 {
            let (_, pages) = try await f.entry("Entry \(index)", in: notebook, pages: 2)
            try await f.ocr(pages[0], "common token\(index)")
            if index.isMultiple(of: 2) { _ = try await f.repository.appendCorrection(pageID: pages[1], text: "corrected page") }
        }
        expectations = [("common", 6), ("corrected", 3), ("token3", 1), ("entry", 6)]
        for (query, count) in expectations { #expect(try await f.search(query).count == count) }
        let incrementalCount = try await f.reader.search("entry", filters: SearchFilters(), limit: 50).count

        try await f.indexer.rebuild()
        for (query, count) in expectations { #expect(try await f.search(query).count == count) }
        #expect(try await f.reader.search("entry", filters: SearchFilters(), limit: 50).count == incrementalCount)
    }

    @Test func crashBeforeCommitKeepsTokenAndReplayIsIdempotent() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        let page = try await f.entry("Crash test", in: notebook).pages[0]
        try await f.ocr(page, "before crash")
        #expect(try await f.search("before").count == 1)
        let tokenBefore = try #require(try await f.indexer.storedToken())

        // Simulated crash after writing index rows but before COMMIT: neither rows nor token persist.
        _ = try await f.repository.appendCorrection(pageID: page, text: "after crash")
        await f.indexer.setFailBeforeCommit(true)
        await #expect(throws: SearchIndexer.IndexerError.self) { try await f.indexer.catchUp() }
        #expect(try await f.indexer.storedToken() == tokenBefore)
        #expect(try await f.reader.search("before", filters: SearchFilters(), limit: 10).count == 1)
        #expect(try await f.reader.search("after", filters: SearchFilters(), limit: 10).isEmpty)

        // Relaunch: reopen the index files and replay.
        await f.indexer.setFailBeforeCommit(false)
        try f.reopenIndex()
        #expect(try await f.indexer.catchUp() == false) // replayed from history, not rebuilt
        #expect(try await f.search("after").count == 1)
        #expect(try await f.search("before").isEmpty)
        let tokenAfter = try #require(try await f.indexer.storedToken())
        #expect(tokenAfter != tokenBefore)

        // Replaying already-applied history again changes nothing.
        try await f.indexer.overwriteStoredToken(tokenBefore)
        #expect(try await f.indexer.catchUp() == false)
        #expect(try await f.search("after").count == 1)
        #expect(try await f.search("crash").count == 1)
    }

    @Test func storeMismatchOrBadTokenTriggersRebuild() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        _ = try await f.entry("Mismatch", in: notebook)
        #expect(try await f.indexer.catchUp()) // first run builds
        #expect(try await f.indexer.catchUp() == false)

        try await f.indexer.overwriteStoreIdentifier("a-different-store")
        #expect(await f.indexer.needsRebuild())
        #expect(try await f.indexer.catchUp())
        #expect(try await f.search("mismatch").count == 1)

        try await f.indexer.overwriteStoredToken(Data("not a token".utf8))
        #expect(try await f.indexer.catchUp())
        try await f.indexer.overwriteStoredToken(nil)
        #expect(try await f.indexer.catchUp())
        #expect(try await f.search("mismatch").count == 1)
    }

    @Test func coordinatorConfiguresUpdatesAndRebuilds() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let coordinator = SearchCoordinator(directory: f.folder.appendingPathComponent("CoordinatorIndex", isDirectory: true))
        let notebook = try await f.notebook("Journal")
        let page = try await f.entry("Coordinator", in: notebook).pages[0]
        await coordinator.configure(container: try #require(f.store.container))
        #expect(coordinator.status == .ready)
        #expect(try await coordinator.search("coordinator", filters: SearchFilters()).count == 1)

        try await f.ocr(page, "fresh words")
        await coordinator.requestUpdate()
        #expect(try await coordinator.search("fresh", filters: SearchFilters()).count == 1)

        await coordinator.rebuild()
        #expect(coordinator.status == .ready)
        #expect(try await coordinator.search("fresh", filters: SearchFilters()).count == 1)
    }

    @Test func boundedFallbackMatchesCanonicalText() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        let page = try await f.entry("Fallback", in: notebook).pages[0]
        try await f.ocr(page, "Jhon 3:16")
        _ = try await f.repository.appendCorrection(pageID: page, text: "John 3:16")
        let fallback = FallbackSearcher(container: try #require(f.store.container))
        #expect(try await fallback.search("john 3:16", filters: SearchFilters(), limit: 10).map(\.pageID) == [page])
        #expect(try await fallback.search("jhon", filters: SearchFilters(), limit: 10).isEmpty)
        #expect(try await fallback.search("fallback", filters: SearchFilters(), limit: 10).count == 1)
    }

    // MARK: Navigation

    @Test func resultOpensItsExactPage() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Journal")
        let (entry, pages) = try await f.entry("Three pages", in: notebook, pages: 3)
        try await f.ocr(pages[2], "the needle is here")
        let hit = try #require(try await f.search("needle").first)
        #expect(hit.entryID == entry)
        #expect(hit.pageID == pages[2])
        #expect(hit.pageNumber == 3)

        // The entry screen opens the result's page, not page 1.
        #expect(EntryNavigation.pageToShow(current: nil, livePageIDs: pages, target: hit.pageID) == pages[2])
        // An already selected live page is kept; a removed target falls back to the first page.
        #expect(EntryNavigation.pageToShow(current: pages[1], livePageIDs: pages, target: hit.pageID) == pages[1])
        #expect(EntryNavigation.pageToShow(current: nil, livePageIDs: [pages[0], pages[1]], target: pages[2]) == pages[0])

        // The relevant words are emphasized in the opened page's text.
        let ranges = SearchQuery.emphasisRanges(in: "the needle is here", terms: SearchQuery.terms(from: "needle"))
        #expect(ranges.map { String("the needle is here"[$0]) } == ["needle"])
    }

    // MARK: Performance (synthetic corpus only)

    @Test func syntheticCorpusQueryLatency() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SearchPerf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try SearchCoordinator.prepare(folder)
        let database = try SearchDatabase(url: folder.appendingPathComponent(SearchDatabase.fileName))
        let vocabulary = ["morning", "prayer", "garden", "letter", "family", "river", "mercy", "harvest", "travel", "school",
                          "psalm", "kitchen", "winter", "summer", "friend", "church", "music", "storm", "quiet", "bread"]
        var generator = SystemRandomNumberGenerator()
        let pageCount = 20_000
        let notebooks = (0..<10).map { _ in UUID() }
        let insertStart = Date()
        try database.transaction {
            for index in 0..<pageCount {
                let words = (0..<120).map { _ in vocabulary[Int.random(in: 0..<vocabulary.count, using: &generator)] }
                try database.insert(SearchDocument(docID: "p\(index)", pageID: UUID(), entryID: UUID(),
                    notebookID: notebooks[index % notebooks.count], pageNumber: 1, imageVersion: nil,
                    journalDate: Date(timeIntervalSinceReferenceDate: Double(index) * 3_600), isFavorite: index % 7 == 0,
                    isReviewed: index % 3 == 0, body: words.joined(separator: " ") + " verse \(index % 150):\(index % 30)",
                    title: "Entry \(index)", notebookName: "Notebook \(index % notebooks.count)"))
            }
        }
        let insertSeconds = Date().timeIntervalSince(insertStart)

        var worst: TimeInterval = 0
        for query in ["mercy", "pray", "garden river", "\"quiet storm\"", "verse 12:5", "harv", "nomatchword"] {
            for filters in [SearchFilters(), SearchFilters(notebookID: notebooks[3], favoritesOnly: true)] {
                let start = Date()
                let expression = try #require(SearchQuery.ftsExpression(from: query))
                let hits = try database.search(expression: expression, filters: filters, limit: SearchCoordinator.resultLimit)
                worst = max(worst, Date().timeIntervalSince(start))
                #expect(hits.count <= SearchCoordinator.resultLimit)
            }
        }
        #expect(try database.documentCount() == pageCount)
        // Generous bound so the check is stable on CI and older devices; actual timings are reported below.
        #expect(worst < 1.0, "Slowest query took \(worst) s over \(pageCount) synthetic pages")
        print("Search performance (synthetic): inserted \(pageCount) pages in \(String(format: "%.2f", insertSeconds)) s; slowest query \(String(format: "%.3f", worst)) s")
    }

    @Test func syntheticCoreDataRebuildTime() async throws {
        let f = try await SearchFixture()
        defer { f.close() }
        let notebook = try await f.notebook("Synthetic")
        for index in 0..<300 {
            let (_, pages) = try await f.entry("Synthetic \(index)", in: notebook, pages: 2)
            try await f.ocr(pages[0], "synthetic body text number \(index) with river and mercy")
        }
        let start = Date()
        try await f.indexer.rebuild()
        let seconds = Date().timeIntervalSince(start)
        #expect(try await f.search("synthetic").count == SearchCoordinator.resultLimit)
        #expect(seconds < 10, "Rebuild of 300 entries took \(seconds) s")
        print("Search performance (synthetic): rebuilt 300 entries / 600 pages in \(String(format: "%.2f", seconds)) s")
    }
}
