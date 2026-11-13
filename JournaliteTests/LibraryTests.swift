import CoreData
import Foundation
import Testing
@testable import Journalite

@MainActor
struct LibraryTests {
    private func withStore(_ body: (PersistenceController, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Library.sqlite")
        let store = PersistenceController(location: .sqlite(url))
        defer {
            try? store.close()
            try? FileManager.default.removeItem(at: folder)
        }
        try await store.load()
        try await body(store, url)
    }

    private func createEntry(_ repository: JournalRepository, notebook: UUID, date: Date = Date()) async throws -> UUID {
        try await repository.createEntry(
            notebookID: notebook, title: "Fixture", journalDate: date,
            pages: [PageDraft(sourceData: Data(repeating: 1, count: 100_000),
                contentType: "image/jpeg", pixelWidth: 10, pixelHeight: 10, sourceKind: "import", sourceHash: nil)]
        )
    }

    @Test func notebookValidationSuggestionsAndMetadataSurviveReopen() async throws {
        try await withStore { store, url in
            let repository = try store.repository()
            try await repository.createStarterNotebooks(names: [])
            #expect(try await repository.notebooks().isEmpty)
            try await repository.createStarterNotebooks(names: ["Bible Notes"])
            try await repository.createStarterNotebooks(names: ["Bible Notes"])
            #expect(try await repository.notebooks().map(\.name) == ["Bible Notes"])
            let id = try await repository.createNotebook(name: "  Personal  \n", colorToken: "blue", symbolName: "heart")
            #expect(try await repository.notebooks().first { $0.id == id }?.name == "Personal")
            do {
                _ = try await repository.createNotebook(name: " \n ")
                Issue.record("Blank name was accepted")
            } catch {}
            do {
                try await repository.updateNotebook(id: id, name: " \t", colorToken: "orange", symbolName: "star")
                Issue.record("Blank rename was accepted")
            } catch {}
            #expect(try await repository.notebooks().first { $0.id == id }?.name == "Personal")
            try await repository.updateNotebook(id: id, name: "  Renamed  ", colorToken: "purple", symbolName: "envelope")
            try store.close()
            let reopened = PersistenceController(location: .sqlite(url))
            try await reopened.load()
            defer { try? reopened.close() }
            let saved = try #require(try await reopened.repository().notebooks().first { $0.id == id })
            #expect(saved.name == "Renamed")
            #expect(saved.colorToken == "purple")
            #expect(saved.symbolName == "envelope")
        }
    }

    @Test func metadataMoveAndPaginationPreserveIdentity() async throws {
        try await withStore { store, url in
            let repository = try store.repository()
            let source = try await repository.createNotebook(name: "Source")
            let destination = try await repository.createNotebook(name: "Destination")
            let date = Date(timeIntervalSince1970: 1_000_000)
            var ids: [UUID] = []
            for _ in 0..<5 { ids.append(try await createEntry(repository, notebook: source, date: date)) }
            let first = try await repository.entries(notebookID: source, limit: 2)
            let second = try await repository.entries(notebookID: source, offset: 2, limit: 2)
            let third = try await repository.entries(notebookID: source, offset: 4, limit: 2)
            let pagedIDs = (first.entries + second.entries + third.entries).map(\.id)
            #expect(pagedIDs == ids.sorted { $0.uuidString < $1.uuidString })
            #expect(first.hasMore && second.hasMore && !third.hasMore)
            let entryID = try #require(ids.first)
            let oldPages = try await repository.pages(entryID: entryID)
            let oldThumbnail = try await repository.entry(id: entryID).thumbnailID
            let newDate = date.addingTimeInterval(100)
            try await repository.updateEntry(id: entryID, title: "  Updated  ", journalDate: newDate, isFavorite: true, notebookID: destination)
            #expect(try await repository.entries(notebookID: source).entries.count == 4)
            #expect(try await repository.entries(notebookID: destination).entries.map(\.id) == [entryID])
            try store.close()
            let reopened = PersistenceController(location: .sqlite(url))
            try await reopened.load()
            defer { try? reopened.close() }
            let read = try reopened.repository()
            let saved = try await read.entry(id: entryID)
            #expect(saved.id == entryID && saved.title == "Updated" && saved.isFavorite)
            #expect(saved.journalDate == newDate && saved.notebookID == destination)
            #expect(saved.thumbnailID == oldThumbnail)
            #expect(try await read.pages(entryID: entryID).map(\.id) == oldPages.map(\.id))
            #expect(try await read.entries(limit: 1).entries.first?.id == entryID)
        }
    }

    @Test func notebookTrashRestoreKeepsPreviouslyTrashedEntriesDeleted() async throws {
        try await withStore { store, _ in
            var repository = try store.repository()
            let notebook = try await repository.createNotebook(name: "Notebook")
            let live = try await createEntry(repository, notebook: notebook)
            let previouslyDeleted = try await createEntry(repository, notebook: notebook)
            try await repository.trashEntry(id: previouslyDeleted)
            try await repository.trashNotebook(id: notebook)
            try store.close()
            try await store.load()
            repository = try store.repository()
            #expect(try await repository.notebooks().isEmpty)
            #expect(try await repository.entries().entries.isEmpty)
            #expect(try await repository.entries(trashed: true).entries.count == 2)
            try await repository.restoreNotebook(id: notebook)
            try store.close()
            try await store.load()
            repository = try store.repository()
            #expect(try await repository.entries().entries.map(\.id) == [live])
            #expect(try await repository.entries(trashed: true).entries.map(\.id) == [previouslyDeleted])
            try await repository.restoreEntry(id: previouslyDeleted)
            #expect(try await repository.entry(id: previouslyDeleted).notebookID == notebook)
        }
    }

    @Test func restoreFromTrashedOrMissingNotebookUsesLiveDestination() async throws {
        try await withStore { store, _ in
            let repository = try store.repository()
            let notebook = try await repository.createNotebook(name: "Notebook")
            let entry = try await createEntry(repository, notebook: notebook)
            let pages = try await repository.pages(entryID: entry)
            try await repository.trashNotebook(id: notebook)
            try await repository.restoreEntry(id: entry)
            let restored = try await repository.entry(id: entry)
            #expect(restored.notebookName == "Restored Entries")
            #expect(!restored.notebookUnavailable && restored.notebookID != notebook)
            #expect(try await repository.pages(entryID: entry).map(\.id) == pages.map(\.id))
            try await repository.permanentlyDelete(id: notebook, notebook: true)
            #expect(try await repository.entry(id: entry).id == entry)

            // A future partially delivered relationship is represented honestly and can be repaired.
            let container = try #require(store.container)
            let context = container.newBackgroundContext()
            try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "JournalEntry")
                request.predicate = NSPredicate(format: "id == %@", entry as NSUUID)
                let object = try #require(context.fetch(request).first)
                object.setValue(nil, forKey: "notebook")
                try context.save()
            }
            #expect(try await repository.entry(id: entry).notebookUnavailable)
            #expect(try await repository.entries().entries.map(\.id) == [entry])
            try await repository.trashEntry(id: entry)
            try await repository.restoreEntry(id: entry)
            #expect(try await repository.entry(id: entry).notebookID == restored.notebookID)
        }
    }

    @Test func movingNotebookContentsAndPermanentDeleteAreSafe() async throws {
        try await withStore { store, _ in
            let repository = try store.repository()
            let source = try await repository.createNotebook(name: "Source")
            let destination = try await repository.createNotebook(name: "Destination")
            let entry = try await createEntry(repository, notebook: source)
            let trashed = try await createEntry(repository, notebook: source)
            let pageIDs = try await repository.pages(entryID: entry).map(\.id)
            let pageID = try #require(pageIDs.first)
            _ = try await repository.appendCorrection(pageID: pageID, text: "")
            try await repository.trashEntry(id: trashed)
            try await repository.trashNotebook(id: source, movingEntriesTo: destination)
            try await repository.permanentlyDelete(id: source, notebook: true)
            #expect(try await repository.entry(id: entry).notebookID == destination)
            #expect(try await repository.pages(entryID: entry).map(\.id) == pageIDs)
            #expect(try await repository.entries(trashed: true).entries.first?.notebookID == destination)
            do {
                try await repository.permanentlyDelete(id: entry, notebook: false)
                Issue.record("Live entry was permanently deleted")
            } catch {}
            try await repository.trashNotebook(id: destination)
            try await repository.permanentlyDelete(id: destination, notebook: true)
            let container = try #require(store.container)
            let context = container.newBackgroundContext()
            try await context.perform {
                for entity in ["Notebook", "JournalEntry", "JournalPage", "PageImage", "TranscriptRevision"] {
                    let count = try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))
                    #expect(count == 0)
                }
            }
        }
    }
}
