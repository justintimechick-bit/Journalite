import CoreData
import Foundation

struct NotebookSummary: Identifiable, Sendable {
    let id: UUID
    let name: String
    let colorToken: String
    let symbolName: String
}

struct PageDraft: Sendable {
    let sourceData: Data
    let contentType: String
    let pixelWidth: Int64
    let pixelHeight: Int64
    let sourceKind: String
    let sourceHash: String?
}

struct PageSummary: Identifiable, Sendable {
    let id: UUID
    let position: Int64
    let text: String?
    let imageID: UUID?
    let revisionCount: Int
}

/// Each operation uses its own private context and returns values, never managed objects.
@MainActor
final class JournalRepository {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func context() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.transactionAuthor = "Journalite.local"
        context.undoManager = nil
        return context
    }

    func notebooks(trashed: Bool = false) async throws -> [NotebookSummary] {
        let context = context()
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Notebook")
            request.predicate = NSPredicate(format: trashed ? "deletedAt != nil" : "deletedAt == nil")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return try context.fetch(request).map {
                guard let id = $0.value(forKey: "id") as? UUID,
                      let name = $0.value(forKey: "name") as? String else {
                    throw PersistenceError.invalidRecord
                }
                return NotebookSummary(id: id, name: name, colorToken: $0.value(forKey: "colorToken") as? String ?? "ink", symbolName: $0.value(forKey: "symbolName") as? String ?? "book.closed")
            }.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
        }
    }

    func createNotebook(name: String, colorToken: String = "ink", symbolName: String = "book.closed") async throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw PersistenceError.invalidRecord
        }
        let context = context()
        return try await context.perform {
            let notebook = Self.insert("Notebook", into: context)
            notebook.setValue(name, forKey: "name")
            notebook.setValue(colorToken, forKey: "colorToken")
            notebook.setValue(symbolName, forKey: "symbolName")
            try context.save()
            return try Self.id(of: notebook)
        }
    }

    func createEntry(notebookID: UUID, title: String, journalDate: Date, pages: [PageDraft]) async throws -> UUID {
        let context = context()
        return try await context.perform {
            let notebook = try Self.find("Notebook", id: notebookID, in: context)
            try Self.requireLive(notebook)
            let entry = Self.insert("JournalEntry", into: context)
            entry.setValue(title, forKey: "title")
            entry.setValue(journalDate, forKey: "journalDate")
            entry.setValue(false, forKey: "isFavorite")
            entry.setValue(notebook, forKey: "notebook")
            for (position, draft) in pages.enumerated() {
                guard !draft.sourceData.isEmpty, draft.pixelWidth > 0, draft.pixelHeight > 0 else {
                    throw PersistenceError.invalidRecord
                }
                let page = Self.insert("JournalPage", into: context)
                page.setValue(entry, forKey: "entry")
                page.setValue(Int64(position), forKey: "position")
                page.setValue(UUID(), forKey: "imageVersion")
                page.setValue(draft.sourceKind, forKey: "sourceKind")
                page.setValue(draft.sourceHash, forKey: "sourceHash")
                let image = Self.insert("PageImage", into: context)
                image.setValue(draft.sourceData, forKey: "sourceData")
                image.setValue(draft.contentType, forKey: "contentType")
                image.setValue(draft.pixelWidth, forKey: "pixelWidth")
                image.setValue(draft.pixelHeight, forKey: "pixelHeight")
                image.setValue(Int64(draft.sourceData.count), forKey: "byteCount")
                image.setValue(page, forKey: "page")
            }
            try context.save()
            return try Self.id(of: entry)
        }
    }

    /// There is deliberately no API for replacing source bytes or editing an existing revision.
    /// `baseRevisionID` omitted: the new revision is based on the currently selected one.
    /// Passed (including `.some(nil)` for a draft started from OCR): recorded exactly, so a
    /// draft saved after a conflict keeps its true lineage.
    @discardableResult
    func appendCorrection(pageID: UUID, text: String, baseRevisionID: UUID?? = nil) async throws -> UUID {
        let context = context()
        return try await context.perform {
            let page = try Self.find("JournalPage", id: pageID, in: context)
            try Self.requireLive(page)
            let revision = Self.insert("TranscriptRevision", into: context)
            revision.setValue(page, forKey: "page")
            revision.setValue(text, forKey: "text")
            let base = baseRevisionID ?? (page.value(forKey: "selectedTranscriptRevisionID") as? UUID)
            revision.setValue(base, forKey: "baseRevisionID")
            revision.setValue(page.value(forKey: "imageVersion"), forKey: "imageVersion")
            let id = try Self.id(of: revision)
            page.setValue(id, forKey: "selectedTranscriptRevisionID")
            page.setValue(nil, forKey: "reviewedRevisionID")
            page.setValue(Date(), forKey: "updatedAt")
            try context.save()
            return id
        }
    }

    func revisions(pageID: UUID) async throws -> [TranscriptRevisionSummary] {
        let context = context()
        return try await context.perform {
            let page = try Self.find("JournalPage", id: pageID, in: context)
            let selected = page.value(forKey: "selectedTranscriptRevisionID") as? UUID
            let revSet = page.value(forKey: "transcriptRevisions") as? Set<NSManagedObject> ?? []
            let summaries: [TranscriptRevisionSummary] = revSet.compactMap { obj in
                guard let id = obj.value(forKey: "id") as? UUID,
                      let text = obj.value(forKey: "text") as? String,
                      let created = obj.value(forKey: "createdAt") as? Date else { return nil }
                return TranscriptRevisionSummary(
                    id: id,
                    text: text,
                    createdAt: created,
                    baseRevisionID: obj.value(forKey: "baseRevisionID") as? UUID,
                    imageVersion: obj.value(forKey: "imageVersion") as? UUID,
                    isSelected: id == selected
                )
            }
            return TranscriptSelectionLogic.orderedRevisions(summaries)
        }
    }

    @discardableResult
    func restoreRevision(pageID: UUID, revisionID: UUID) async throws -> UUID {
        let context = context()
        return try await context.perform {
            let page = try Self.find("JournalPage", id: pageID, in: context)
            try Self.requireLive(page)
            let target = try Self.find("TranscriptRevision", id: revisionID, in: context)
            guard target.value(forKey: "page") as? NSManagedObject == page else { throw PersistenceError.invalidRecord }
            let text = target.value(forKey: "text") as? String ?? ""
            let newRevision = Self.insert("TranscriptRevision", into: context)
            newRevision.setValue(page, forKey: "page")
            newRevision.setValue(text, forKey: "text")
            newRevision.setValue(page.value(forKey: "selectedTranscriptRevisionID"), forKey: "baseRevisionID")
            newRevision.setValue(page.value(forKey: "imageVersion"), forKey: "imageVersion")
            let id = try Self.id(of: newRevision)
            page.setValue(id, forKey: "selectedTranscriptRevisionID")
            page.setValue(nil, forKey: "reviewedRevisionID")
            page.setValue(Date(), forKey: "updatedAt")
            try context.save()
            return id
        }
    }

    func markPageReviewed(pageID: UUID, reviewed: Bool) async throws {
        let context = context()
        try await context.perform {
            let page = try Self.find("JournalPage", id: pageID, in: context)
            try Self.requireLive(page)
            if reviewed {
                let activeID = (page.value(forKey: "selectedTranscriptRevisionID") as? UUID) ?? (page.value(forKey: "ocrResultID") as? UUID)
                page.setValue(activeID, forKey: "reviewedRevisionID")
            } else {
                page.setValue(nil, forKey: "reviewedRevisionID")
            }
            page.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
    }

    func pageDetail(pageID: UUID) async throws -> PageDetail? {
        let context = context()
        return try await context.perform {
            guard let page = try? Self.find("JournalPage", id: pageID, in: context) else { return nil }
            guard page.value(forKey: "deletedAt") == nil else { return nil }
            guard let version = page.value(forKey: "imageVersion") as? UUID else { throw PersistenceError.invalidRecord }
            let position = (page.value(forKey: "position") as? NSNumber)?.int64Value ?? 0
            let imageID = (page.value(forKey: "image") as? NSManagedObject)?.value(forKey: "id") as? UUID
            let selected = page.value(forKey: "selectedTranscriptRevisionID") as? UUID
            let reviewed = page.value(forKey: "reviewedRevisionID") as? UUID
            let rawOCR = page.value(forKey: "rawOCRText") as? String
            let ocrResult = page.value(forKey: "ocrResultID") as? UUID
            let lowConf = (page.value(forKey: "ocrLowConfidenceLineCount") as? NSNumber)?.intValue ?? 0

            let revSet = page.value(forKey: "transcriptRevisions") as? Set<NSManagedObject> ?? []
            let unordered: [TranscriptRevisionSummary] = revSet.compactMap { obj in
                guard let id = obj.value(forKey: "id") as? UUID,
                      let text = obj.value(forKey: "text") as? String,
                      let created = obj.value(forKey: "createdAt") as? Date else { return nil }
                return TranscriptRevisionSummary(
                    id: id,
                    text: text,
                    createdAt: created,
                    baseRevisionID: obj.value(forKey: "baseRevisionID") as? UUID,
                    imageVersion: obj.value(forKey: "imageVersion") as? UUID,
                    isSelected: id == selected
                )
            }
            let revSummaries = TranscriptSelectionLogic.orderedRevisions(unordered)

            let resolution = TranscriptSelectionLogic.resolveCanonicalText(
                selectedRevisionID: selected,
                rawOCRText: rawOCR,
                ocrResultID: ocrResult,
                revisions: revSummaries
            )
            let isReviewed = TranscriptSelectionLogic.computeIsReviewed(
                selectedRevisionID: selected,
                ocrResultID: ocrResult,
                reviewedRevisionID: reviewed
            )
            return PageDetail(
                id: pageID,
                position: position,
                imageID: imageID,
                imageVersion: version,
                rawOCRText: rawOCR,
                ocrResultID: ocrResult,
                selectedRevisionID: selected,
                reviewedRevisionID: reviewed,
                isReviewed: isReviewed,
                revisions: revSummaries,
                canonicalResolution: resolution,
                lowConfidenceLineCount: lowConf
            )
        }
    }

    @discardableResult
    func addPages(to entryID: UUID, drafts: [PageDraft]) async throws -> [UUID] {
        guard !drafts.isEmpty else { return [] }
        let context = context()
        return try await context.perform {
            let entry = try Self.find("JournalEntry", id: entryID, in: context)
            try Self.requireLive(entry)
            guard entry.value(forKey: "pendingIngestionID") == nil else { throw PersistenceError.notLoaded }
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
            request.predicate = NSPredicate(format: "entry == %@ AND deletedAt == nil", entry)
            let existingPages = try context.fetch(request)
            let maxPos = existingPages.map { ($0.value(forKey: "position") as? NSNumber)?.int64Value ?? 0 }.max() ?? -1

            var newIDs: [UUID] = []
            for (index, draft) in drafts.enumerated() {
                guard !draft.sourceData.isEmpty, draft.pixelWidth > 0, draft.pixelHeight > 0 else {
                    throw PersistenceError.invalidRecord
                }
                let page = Self.insert("JournalPage", into: context)
                let pageID = try Self.id(of: page)
                page.setValue(entry, forKey: "entry")
                page.setValue(maxPos + 1 + Int64(index), forKey: "position")
                page.setValue(UUID(), forKey: "imageVersion")
                page.setValue(draft.sourceKind, forKey: "sourceKind")
                page.setValue(draft.sourceHash, forKey: "sourceHash")

                let image = Self.insert("PageImage", into: context)
                image.setValue(draft.sourceData, forKey: "sourceData")
                image.setValue(draft.contentType, forKey: "contentType")
                image.setValue(draft.pixelWidth, forKey: "pixelWidth")
                image.setValue(draft.pixelHeight, forKey: "pixelHeight")
                image.setValue(Int64(draft.sourceData.count), forKey: "byteCount")
                image.setValue(page, forKey: "page")

                newIDs.append(pageID)
            }
            entry.setValue(Date(), forKey: "updatedAt")
            try context.save()
            return newIDs
        }
    }

    func reorderPages(entryID: UUID, pageIDs: [UUID]) async throws {
        let context = context()
        try await context.perform {
            let entry = try Self.find("JournalEntry", id: entryID, in: context)
            try Self.requireLive(entry)
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
            request.predicate = NSPredicate(format: "entry == %@ AND deletedAt == nil", entry)
            let pages = try context.fetch(request)
            let pageMap = Dictionary(uniqueKeysWithValues: try pages.map { (try Self.id(of: $0), $0) })
            for (newPos, id) in pageIDs.enumerated() {
                if let page = pageMap[id] {
                    page.setValue(Int64(newPos), forKey: "position")
                    page.setValue(Date(), forKey: "updatedAt")
                }
            }
            entry.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
    }

    func removePage(id pageID: UUID) async throws {
        let context = context()
        try await context.perform {
            let page = try Self.find("JournalPage", id: pageID, in: context)
            try Self.requireLive(page)
            let entry = page.value(forKey: "entry") as? NSManagedObject
            Self.mark(page, deletedAt: Date())
            if let entry {
                let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
                request.predicate = NSPredicate(format: "entry == %@ AND deletedAt == nil", entry)
                request.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true), NSSortDescriptor(key: "id", ascending: true)]
                let remaining = try context.fetch(request)
                for (index, remainingPage) in remaining.enumerated() {
                    remainingPage.setValue(Int64(index), forKey: "position")
                }
                entry.setValue(Date(), forKey: "updatedAt")
            }
            try context.save()
        }
    }

    func restorePage(id pageID: UUID) async throws {
        let context = context()
        try await context.perform {
            let page = try Self.find("JournalPage", id: pageID, in: context)
            guard page.value(forKey: "deletedAt") != nil else { throw PersistenceError.invalidRecord }
            let entry = page.value(forKey: "entry") as? NSManagedObject
            Self.mark(page, deletedAt: nil)
            if let entry {
                let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
                request.predicate = NSPredicate(format: "entry == %@ AND deletedAt == nil", entry)
                let count = try context.count(for: request)
                page.setValue(Int64(count - 1), forKey: "position")
                entry.setValue(Date(), forKey: "updatedAt")
            }
            try context.save()
        }
    }

    func deletedPages(entryID: UUID) async throws -> [PageSummary] {
        let context = context()
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
            request.predicate = NSPredicate(format: "entry.id == %@ AND deletedAt != nil", entryID as NSUUID)
            request.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true), NSSortDescriptor(key: "id", ascending: true)]
            let pages = try context.fetch(request)
            return try pages.map { page in
                let revisions = page.value(forKey: "transcriptRevisions") as? Set<NSManagedObject> ?? []
                let selected = page.value(forKey: "selectedTranscriptRevisionID") as? UUID
                let text: String?
                if let selected {
                    text = revisions.first { ($0.value(forKey: "id") as? UUID) == selected }?.value(forKey: "text") as? String
                } else {
                    text = page.value(forKey: "rawOCRText") as? String
                }
                return PageSummary(
                    id: try Self.id(of: page),
                    position: (page.value(forKey: "position") as? NSNumber)?.int64Value ?? 0,
                    text: text,
                    imageID: (page.value(forKey: "image") as? NSManagedObject)?.value(forKey: "id") as? UUID,
                    revisionCount: revisions.count
                )
            }
        }
    }

    func pages(entryID: UUID) async throws -> [PageSummary] {
        let context = context()
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
            request.predicate = NSPredicate(format: "entry.id == %@ AND deletedAt == nil", entryID as NSUUID)
            let pages = try context.fetch(request).map { page in
                let revisions = page.value(forKey: "transcriptRevisions") as? Set<NSManagedObject> ?? []
                let selected = page.value(forKey: "selectedTranscriptRevisionID") as? UUID
                let text: String?
                if let selected {
                    // Missing selected revisions must not silently fall back to raw OCR.
                    text = revisions.first { ($0.value(forKey: "id") as? UUID) == selected }?.value(forKey: "text") as? String
                } else {
                    text = page.value(forKey: "rawOCRText") as? String
                }
                return PageSummary(
                    id: try Self.id(of: page),
                    position: (page.value(forKey: "position") as? NSNumber)?.int64Value ?? 0,
                    text: text,
                    imageID: (page.value(forKey: "image") as? NSManagedObject)?.value(forKey: "id") as? UUID,
                    revisionCount: revisions.count
                )
            }
            // UUID tie-break makes malformed/merged duplicate positions deterministic.
            return pages.sorted {
                $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position
            }
        }
    }

    nonisolated static func insert(_ entity: String, into context: NSManagedObjectContext) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        object.setValue(UUID(), forKey: "id")
        let now = Date()
        for key in ["createdAt", "updatedAt"] where object.entity.attributesByName[key] != nil {
            object.setValue(now, forKey: key)
        }
        return object
    }

    nonisolated static func id(of object: NSManagedObject) throws -> UUID {
        guard let id = object.value(forKey: "id") as? UUID else { throw PersistenceError.invalidRecord }
        return id
    }

    nonisolated static func find(_ entity: String, id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 2
        let results = try context.fetch(request)
        guard results.count == 1, let result = results.first else { throw PersistenceError.missingRecord }
        return result
    }
}
