import CoreData
import Foundation

extension JournalRepository {
    func containsSource(hash: String) async throws -> Bool {
        let context = context()
        return try await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "JournalPage")
            request.predicate = NSPredicate(format: "sourceHash == %@", hash)
            request.fetchLimit = 1
            return try context.count(for: request) > 0
        }
    }

    /// Each page is committed independently and the context reset, bounding retained binary data.
    /// Pending entries are invisible until all receipt-owned pages pass read-back verification.
    func commit(_ receipt: IngestionReceipt, directory: URL) async throws {
        guard receipt.phase == .saving, !receipt.pages.isEmpty,
              receipt.pages.count <= ImportLimits.pages,
              let notebookID = receipt.notebookID else { throw IngestionError.empty }
        let context = context()
        try await context.perform {
            let notebook = try Self.find("Notebook", id: notebookID, in: context)
            try Self.requireLive(notebook)
            for (index, entryID) in receipt.entryIDs.enumerated() {
                if let existing = try Self.optionalObject("JournalEntry", id: entryID, context: context) {
                    let pending = existing.value(forKey: "pendingIngestionID") as? UUID
                    guard pending == nil || pending == receipt.id else { throw IngestionError.conflict }
                } else {
                    let entry = Self.insert("JournalEntry", into: context)
                    entry.setValue(entryID, forKey: "id")
                    entry.setValue(receipt.id, forKey: "pendingIngestionID")
                    entry.setValue(receipt.createdAt, forKey: "createdAt")
                    entry.setValue(receipt.title.isEmpty ? "" : receipt.title + (receipt.separateEntries ? " (\(index + 1))" : ""), forKey: "title")
                    entry.setValue(receipt.journalDate, forKey: "journalDate")
                    entry.setValue(notebook, forKey: "notebook")
                    entry.setValue(false, forKey: "isFavorite")
                }
            }
            if context.hasChanges { try context.save() }
            context.reset()
        }

        for (position, page) in receipt.pages.enumerated() {
            try Task.checkCancellation()
            try await context.perform {
                try autoreleasepool {
                    if let existing = try Self.optionalObject("JournalPage", id: page.id, context: context) {
                        guard existing.value(forKey: "sourceHash") as? String == page.hash,
                              (existing.value(forKey: "image") as? NSManagedObject)?.value(forKey: "id") as? UUID == page.imageID else {
                            throw IngestionError.conflict
                        }
                    } else {
                        let entryID = receipt.separateEntries ? page.singleEntryID : receipt.multipageEntryID
                        let entry = try Self.find("JournalEntry", id: entryID, in: context)
                        guard entry.value(forKey: "pendingIngestionID") as? UUID == receipt.id else { throw IngestionError.conflict }
                        let file = directory.appendingPathComponent(page.id.uuidString + ".source")
                        let info = try ImageProcessing.inspect(file)
                        guard info.byteCount == page.byteCount, try ImageProcessing.hash(file) == page.hash else { throw IngestionError.conflict }
                        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
                        let object = Self.insert("JournalPage", into: context)
                        object.setValue(page.id, forKey: "id")
                        object.setValue(receipt.createdAt, forKey: "createdAt")
                        object.setValue(Int64(receipt.separateEntries ? 0 : position), forKey: "position")
                        object.setValue(page.imageVersion, forKey: "imageVersion")
                        object.setValue(page.sourceKind, forKey: "sourceKind")
                        object.setValue(page.hash, forKey: "sourceHash")
                        object.setValue(entry, forKey: "entry")
                        let image = Self.insert("PageImage", into: context)
                        image.setValue(page.imageID, forKey: "id")
                        image.setValue(bytes, forKey: "sourceData")
                        image.setValue(page.contentType, forKey: "contentType")
                        image.setValue(Int64(page.width), forKey: "pixelWidth")
                        image.setValue(Int64(page.height), forKey: "pixelHeight")
                        image.setValue(Int64(page.byteCount), forKey: "byteCount")
                        image.setValue(object, forKey: "page")
                        try context.save()
                    }
                    context.reset()
                }
            }
        }

        // Read committed bytes in a fresh context, one image at a time, before releasing staging.
        let verification = self.context()
        for (position, page) in receipt.pages.enumerated() {
            try await verification.perform {
                try autoreleasepool {
                    let object = try Self.find("JournalPage", id: page.id, in: verification)
                    let entryID = receipt.separateEntries ? page.singleEntryID : receipt.multipageEntryID
                    guard (object.value(forKey: "entry") as? NSManagedObject)?.value(forKey: "id") as? UUID == entryID,
                          (object.value(forKey: "position") as? NSNumber)?.intValue == (receipt.separateEntries ? 0 : position),
                          let image = object.value(forKey: "image") as? NSManagedObject,
                          image.value(forKey: "id") as? UUID == page.imageID,
                          let bytes = image.value(forKey: "sourceData") as? Data,
                          bytes.count == page.byteCount,
                          ImageProcessing.hash(bytes) == page.hash else { throw IngestionError.conflict }
                    verification.reset()
                }
            }
        }
        try await context.perform {
            for entryID in receipt.entryIDs {
                let entry = try Self.find("JournalEntry", id: entryID, in: context)
                let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "JournalPage")
                countRequest.predicate = NSPredicate(format: "entry == %@", entry)
                guard try context.count(for: countRequest) == (receipt.separateEntries ? 1 : receipt.pages.count) else {
                    throw IngestionError.conflict
                }
                entry.setValue(nil, forKey: "pendingIngestionID")
            }
            if context.hasChanges { try context.save() }
            context.reset()
        }
    }

    /// Explicit viewer/export access only. Library row queries never call this method.
    func writeSource(pageID: UUID, to url: URL) async throws {
        let context = context()
        try await context.perform {
            let page = try Self.find("JournalPage", id: pageID, in: context)
            guard let entry = page.value(forKey: "entry") as? NSManagedObject,
                  entry.value(forKey: "pendingIngestionID") == nil else { throw PersistenceError.missingRecord }
            try Self.requireLive(entry)
            guard let image = page.value(forKey: "image") as? NSManagedObject,
                  let bytes = image.value(forKey: "sourceData") as? Data else { throw PersistenceError.missingRecord }
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            context.reset()
        }
    }

    nonisolated private static func optionalObject(_ entity: String, id: UUID, context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 2
        let objects = try context.fetch(request)
        guard objects.count <= 1 else { throw IngestionError.conflict }
        return objects.first
    }
}
