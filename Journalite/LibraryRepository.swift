import CoreData
import Foundation

struct ThumbnailIdentifier: Hashable, Sendable {
    let pageID: UUID
    let imageVersion: UUID
}

struct EntrySummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let journalDate: Date?
    let isFavorite: Bool
    let notebookID: UUID?
    let notebookName: String?
    let notebookUnavailable: Bool
    let thumbnailID: ThumbnailIdentifier?
}

struct EntryBatch: Sendable {
    let entries: [EntrySummary]
    let hasMore: Bool
}

struct EntryRoute: Hashable {
    let entryID: UUID
    var targetPageID: UUID? = nil
    /// Search text that opened this entry; its words are emphasized in the page text.
    var highlight: String? = nil
}

nonisolated enum EntryNavigation {
    /// Which page to show. Keeps the current page while it still exists; otherwise opens the
    /// requested page (e.g. a search result) if it is live, else the first page.
    static func pageToShow(current: UUID?, livePageIDs: [UUID], target: UUID?) -> UUID? {
        if let current, livePageIDs.contains(current) { return current }
        if let target, livePageIDs.contains(target) { return target }
        return livePageIDs.first
    }
}

extension JournalRepository {
    func createStarterNotebooks(names: [String]) async throws {
        let allowed = Set(["Bible Notes", "Personal Motivation", "Letters to My Family"])
        guard names.allSatisfy({ allowed.contains($0) }) else { throw PersistenceError.invalidRecord }
        let context = context()
        try await context.perform {
            for name in Set(names).sorted() {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Notebook")
                request.predicate = NSPredicate(format: "name == %@ AND deletedAt == nil", name)
                request.fetchLimit = 1
                guard try context.count(for: request) == 0 else { continue }
                let notebook = Self.insert("Notebook", into: context)
                notebook.setValue(name, forKey: "name")
                notebook.setValue("ink", forKey: "colorToken")
                notebook.setValue("book.closed", forKey: "symbolName")
            }
            if context.hasChanges { try context.save() }
        }
    }

    func updateNotebook(id: UUID, name: String, colorToken: String, symbolName: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PersistenceError.invalidRecord }
        let context = context()
        try await context.perform {
            let notebook = try Self.find("Notebook", id: id, in: context)
            try Self.requireLive(notebook)
            notebook.setValue(name, forKey: "name")
            notebook.setValue(colorToken, forKey: "colorToken")
            notebook.setValue(symbolName, forKey: "symbolName")
            notebook.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
    }

    /// Bounded metadata fetches, ordered in SQLite. Refresh pagination after local mutations.
    func entries(notebookID: UUID? = nil, trashed: Bool = false, offset: Int = 0, limit: Int = 25) async throws -> EntryBatch {
        let context = context()
        let limit = min(max(limit, 1), 100)
        return try await context.perform {
            if let notebookID, !trashed {
                try Self.requireLive(Self.find("Notebook", id: notebookID, in: context))
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalEntry")
            var predicates = [NSPredicate(format: "pendingIngestionID == nil"), NSPredicate(format: trashed
                ? "deletedAt != nil"
                : "deletedAt == nil AND (notebook == nil OR notebook.deletedAt == nil)")]
            if let notebookID {
                predicates.append(NSPredicate(format: "notebook.id == %@", notebookID as NSUUID))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [
                NSSortDescriptor(key: "journalDate", ascending: false),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            request.fetchOffset = max(0, offset)
            request.fetchLimit = limit + 1
            let objects = try context.fetch(request)
            return EntryBatch(
                entries: try objects.prefix(limit).map { try Self.summary($0, in: context) },
                hasMore: objects.count > limit
            )
        }
    }

    func entry(id: UUID) async throws -> EntrySummary {
        let context = context()
        return try await context.perform {
            let object = try Self.find("JournalEntry", id: id, in: context)
            guard object.value(forKey: "pendingIngestionID") == nil else { throw PersistenceError.missingRecord }
            try Self.requireLive(object)
            return try Self.summary(object, in: context)
        }
    }

    func updateEntry(id: UUID, title: String, journalDate: Date, isFavorite: Bool, notebookID: UUID) async throws {
        let context = context()
        try await context.perform {
            let entry = try Self.find("JournalEntry", id: id, in: context)
            let notebook = try Self.find("Notebook", id: notebookID, in: context)
            try Self.requireLive(entry)
            try Self.requireLive(notebook)
            entry.setValue(title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "title")
            entry.setValue(journalDate, forKey: "journalDate")
            entry.setValue(isFavorite, forKey: "isFavorite")
            entry.setValue(notebook, forKey: "notebook")
            entry.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
    }

    func trashEntry(id: UUID) async throws {
        let context = context()
        try await context.perform {
            let entry = try Self.find("JournalEntry", id: id, in: context)
            try Self.requireLive(entry)
            Self.mark(entry, deletedAt: Date())
            try context.save()
        }
    }

    /// Moving keeps every entry, including previously trashed entries, and all stable page IDs.
    func trashNotebook(id: UUID, movingEntriesTo destinationID: UUID? = nil) async throws {
        guard destinationID != id else { throw PersistenceError.invalidRecord }
        let context = context()
        try await context.perform {
            let notebook = try Self.find("Notebook", id: id, in: context)
            try Self.requireLive(notebook)
            let destination = try destinationID.map { try Self.find("Notebook", id: $0, in: context) }
            if let destination { try Self.requireLive(destination) }
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalEntry")
            request.predicate = NSPredicate(format: "notebook == %@", notebook)
            let date = Date()
            for entry in try context.fetch(request) {
                if let destination {
                    entry.setValue(destination, forKey: "notebook")
                    entry.setValue(date, forKey: "updatedAt")
                } else if entry.value(forKey: "deletedAt") == nil {
                    // This exact timestamp groups entries trashed with their notebook.
                    Self.mark(entry, deletedAt: date)
                }
            }
            Self.mark(notebook, deletedAt: date)
            try context.save()
        }
    }

    func restoreNotebook(id: UUID) async throws {
        let context = context()
        try await context.perform {
            let notebook = try Self.find("Notebook", id: id, in: context)
            guard let date = notebook.value(forKey: "deletedAt") as? Date else {
                throw PersistenceError.invalidRecord
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalEntry")
            request.predicate = NSPredicate(format: "notebook == %@ AND deletedAt == %@", notebook, date as NSDate)
            for entry in try context.fetch(request) { Self.mark(entry, deletedAt: nil) }
            Self.mark(notebook, deletedAt: nil)
            try context.save()
        }
    }

    func restoreEntry(id: UUID, to notebookID: UUID? = nil) async throws {
        let context = context()
        try await context.perform {
            let entry = try Self.find("JournalEntry", id: id, in: context)
            guard entry.value(forKey: "deletedAt") != nil else { throw PersistenceError.invalidRecord }
            let notebook: NSManagedObject
            if let notebookID {
                notebook = try Self.find("Notebook", id: notebookID, in: context)
                try Self.requireLive(notebook)
            } else if let original = entry.value(forKey: "notebook") as? NSManagedObject,
                      original.value(forKey: "deletedAt") == nil {
                notebook = original
            } else {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Notebook")
                request.predicate = NSPredicate(format: "name == %@ AND deletedAt == nil", "Restored Entries")
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                request.fetchLimit = 1
                if let existing = try context.fetch(request).first {
                    notebook = existing
                } else {
                    notebook = Self.insert("Notebook", into: context)
                    notebook.setValue("Restored Entries", forKey: "name")
                    notebook.setValue("ink", forKey: "colorToken")
                    notebook.setValue("book.closed", forKey: "symbolName")
                }
            }
            entry.setValue(notebook, forKey: "notebook")
            Self.mark(entry, deletedAt: nil)
            try context.save()
        }
    }

    /// Call only after explicit UI confirmation. Reject live objects even if a caller is stale.
    func permanentlyDelete(id: UUID, notebook: Bool) async throws {
        let context = context()
        try await context.perform {
            let object = try Self.find(notebook ? "Notebook" : "JournalEntry", id: id, in: context)
            guard object.value(forKey: "deletedAt") != nil else { throw PersistenceError.invalidRecord }
            context.delete(object)
            // Model cascade rules remove owned pages, images and revisions in the same transaction.
            try context.save()
        }
    }

    nonisolated static func requireLive(_ object: NSManagedObject) throws {
        guard object.value(forKey: "deletedAt") == nil else { throw PersistenceError.missingRecord }
    }

    nonisolated static func mark(_ object: NSManagedObject, deletedAt: Date?) {
        object.setValue(deletedAt, forKey: "deletedAt")
        object.setValue(Date(), forKey: "updatedAt")
    }

    nonisolated private static func summary(_ entry: NSManagedObject, in context: NSManagedObjectContext) throws -> EntrySummary {
        let entryID = try id(of: entry)
        let notebook = entry.value(forKey: "notebook") as? NSManagedObject
        // Fetch only page metadata to form a future thumbnail-cache key. Never fault PageImage.
        let pageRequest = NSFetchRequest<NSDictionary>(entityName: "JournalPage")
        pageRequest.resultType = .dictionaryResultType
        pageRequest.propertiesToFetch = ["id", "imageVersion"]
        pageRequest.predicate = NSPredicate(format: "entry == %@ AND deletedAt == nil", entry)
        pageRequest.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true), NSSortDescriptor(key: "id", ascending: true)]
        pageRequest.fetchLimit = 1
        let first = try context.fetch(pageRequest).first
        let thumbnail: ThumbnailIdentifier?
        if let pageID = first?["id"] as? UUID, let version = first?["imageVersion"] as? UUID {
            thumbnail = ThumbnailIdentifier(pageID: pageID, imageVersion: version)
        } else { thumbnail = nil }
        return EntrySummary(
            id: entryID, title: entry.value(forKey: "title") as? String ?? "",
            journalDate: entry.value(forKey: "journalDate") as? Date,
            isFavorite: entry.value(forKey: "isFavorite") as? Bool ?? false,
            notebookID: notebook?.value(forKey: "id") as? UUID,
            notebookName: notebook?.value(forKey: "name") as? String,
            notebookUnavailable: notebook == nil || notebook?.value(forKey: "deletedAt") != nil,
            thumbnailID: thumbnail
        )
    }
}
