import CoreData
import Foundation
import Testing
@testable import Journalite

@MainActor
struct JournaliteTests {
    @Test func sqliteRoundTripPreservesRelationshipsAndEmptyCorrection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("RoundTrip.sqlite")
        let first = PersistenceController(location: .sqlite(url))
        try await first.load()
        let repository = try first.repository()
        let notebookID = try await repository.createNotebook(name: "Fixture")
        let bytes = Data(repeating: 0x41, count: 200_000)
        let draft = PageDraft(sourceData: bytes, contentType: "image/jpeg", pixelWidth: 100,
                              pixelHeight: 200, sourceKind: "import", sourceHash: nil)
        let entryID = try await repository.createEntry(
            notebookID: notebookID, title: "Fixture entry", journalDate: Date(),
            pages: [draft, draft, draft]
        )
        let original = try await repository.pages(entryID: entryID)
        #expect(original.map(\.position) == [0, 1, 2])
        #expect(Set(original.map(\.id)).count == 3)
        let pageID = try #require(original.first?.id)
        let initialRevision = try await repository.appendCorrection(pageID: pageID, text: "First correction")
        let emptyRevision = try await repository.appendCorrection(pageID: pageID, text: "")
        #expect(initialRevision != emptyRevision)

        let firstContainer = try #require(first.container)
        let context = firstContainer.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
            request.predicate = NSPredicate(format: "id == %@", pageID as NSUUID)
            let page = try #require(context.fetch(request).first)
            page.setValue("Original OCR fixture", forKey: "rawOCRText")
            page.setValue(UUID(), forKey: "ocrResultID")
            try context.save()
        }
        try first.close()
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reopened = PersistenceController(location: .sqlite(url))
        try await reopened.load()
        let read = try reopened.repository()
        #expect(try await read.notebooks().map(\.id) == [notebookID])
        let pages = try await read.pages(entryID: entryID)
        #expect(pages.map(\.id) == original.map(\.id))
        #expect(pages.map(\.position) == [0, 1, 2])
        #expect(pages.first?.text == "")
        #expect(pages.first?.revisionCount == 2)
        #expect(Set(pages.compactMap(\.imageID)).count == 3)

        let container = try #require(reopened.container)
        #expect(container.persistentStoreDescriptions.first?.cloudKitContainerOptions == nil)
        let inspection = container.newBackgroundContext()
        try await inspection.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalEntry")
            let entry = try #require(inspection.fetch(request).first)
            let notebook = try #require(entry.value(forKey: "notebook") as? NSManagedObject)
            #expect(notebook.value(forKey: "id") as? UUID == notebookID)
            #expect((notebook.value(forKey: "entries") as? Set<NSManagedObject>)?.count == 1)
            let ownedPages = try #require(entry.value(forKey: "pages") as? Set<NSManagedObject>)
            #expect(ownedPages.count == 3)
            for page in ownedPages {
                let image = try #require(page.value(forKey: "image") as? NSManagedObject)
                #expect(image.value(forKey: "sourceData") as? Data == bytes)
                #expect(image.value(forKey: "page") as? NSManagedObject === page)
                #expect(page.value(forKey: "entry") as? NSManagedObject === entry)
            }
            let revisionRequest = NSFetchRequest<NSManagedObject>(entityName: "TranscriptRevision")
            let revisions = try inspection.fetch(revisionRequest)
            #expect(revisions.count == 2)
            let empty = try #require(revisions.first { $0.value(forKey: "id") as? UUID == emptyRevision })
            #expect(empty.value(forKey: "text") as? String == "")
            #expect(empty.value(forKey: "baseRevisionID") as? UUID == initialRevision)
            let page = try #require(empty.value(forKey: "page") as? NSManagedObject)
            #expect(page.value(forKey: "rawOCRText") as? String == "Original OCR fixture")
            #expect(empty.value(forKey: "imageVersion") as? UUID == page.value(forKey: "imageVersion") as? UUID)
            let history = NSPersistentHistoryChangeRequest.fetchHistory(after: Date.distantPast)
            let result = try inspection.execute(history) as? NSPersistentHistoryResult
            let transactions = try #require(result?.result as? [NSPersistentHistoryTransaction])
            #expect(transactions.count > 0)

            // Equal positions can occur after future merges. Ordering must still be stable.
            for page in ownedPages { page.setValue(Int64(0), forKey: "position") }
            try inspection.save()
        }
        let tied = try await read.pages(entryID: entryID)
        #expect(tied.map(\.id) == original.map(\.id).sorted { $0.uuidString < $1.uuidString })
        try reopened.close()
    }

    @Test func modelAndMemoryStoreAreIsolated() async throws {
        let first = PersistenceController(location: .memory)
        let second = PersistenceController(location: .memory)
        try await first.load()
        try await second.load()
        _ = try await first.repository().createNotebook(name: "Memory only")
        #expect(try await second.repository().notebooks().isEmpty)
        let container = try #require(first.container)
        #expect(container.persistentStoreCoordinator.persistentStores.first?.type == NSInMemoryStoreType)
        let model = container.managedObjectModel
        #expect(Set(model.entities.compactMap(\.name)) ==
            Set(["Notebook", "JournalEntry", "JournalPage", "PageImage", "TranscriptRevision"]))
        for entity in model.entities {
            #expect(entity.uniquenessConstraints.isEmpty)
            #expect(entity.attributesByName["id"]?.attributeType == .UUIDAttributeType)
            #expect(entity.attributesByName["id"]?.defaultValue == nil)
            for attribute in entity.attributesByName.values {
                #expect(attribute.isOptional || attribute.defaultValue != nil)
            }
            for relationship in entity.relationshipsByName.values {
                #expect(relationship.isOptional)
                #expect(!relationship.isOrdered)
                #expect(relationship.inverseRelationship != nil)
                #expect(relationship.inverseRelationship?.inverseRelationship === relationship)
            }
        }
        #expect(model.entitiesByName["PageImage"]?.attributesByName["sourceData"]?.allowsExternalBinaryDataStorage == true)
        try first.close()
        try second.close()
    }

    @Test func failedLoadPreservesFilesAndCanRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocked")
        let sentinel = Data("Preserve this file".utf8)
        try sentinel.write(to: blocker)
        let controller = PersistenceController(location: .sqlite(blocker.appendingPathComponent("Journal.sqlite")))
        do {
            try await controller.load()
            Issue.record("Loading beneath a regular file should fail")
        } catch {
            #expect(controller.container == nil)
            #expect(try Data(contentsOf: blocker) == sentinel)
        }
        // Only the fixture is repaired explicitly; production code never deletes a failed store.
        try FileManager.default.moveItem(at: blocker, to: directory.appendingPathComponent("preserved"))
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try await controller.load()
        #expect(try await controller.repository().notebooks().isEmpty)
        try controller.close()
    }
}
