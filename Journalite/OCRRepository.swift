import CoreData
import Foundation

nonisolated struct OCRPageSnapshot: Sendable {
    let key: OCRPageKey
    let resultID: UUID?
    let rawText: String?
    let text: String?
    let lowConfidenceLineCount: Int
}

extension JournalRepository {
    func ocrPage(id: UUID) async throws -> OCRPageSnapshot? {
        let context = context()
        return try await context.perform {
            guard let page = try Self.liveOCRPage(id: id, context: context) else { return nil }
            guard let version = page.value(forKey: "imageVersion") as? UUID else { throw PersistenceError.invalidRecord }
            let selected = page.value(forKey: "selectedTranscriptRevisionID") as? UUID
            let revisions = page.value(forKey: "transcriptRevisions") as? Set<NSManagedObject> ?? []
            let matchesImage = page.value(forKey: "ocrImageVersion") as? UUID == version
            let raw = matchesImage ? page.value(forKey: "rawOCRText") as? String : nil
            let text = selected.map { id in
                revisions.first { $0.value(forKey: "id") as? UUID == id }?.value(forKey: "text") as? String
            } ?? raw
            return OCRPageSnapshot(key: OCRPageKey(pageID: id, imageVersion: version),
                resultID: matchesImage ? page.value(forKey: "ocrResultID") as? UUID : nil, rawText: raw, text: text,
                lowConfidenceLineCount: (page.value(forKey: "ocrLowConfidenceLineCount") as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Revalidates source version and live ownership in the same transaction as the result save.
    /// Automatic OCR never deselects a manual revision. An explicit retry (`job.selectsResult`)
    /// makes the new OCR text current; manual revisions are never edited or removed.
    func saveOCR(_ result: OCRResult, job: OCRJob) async throws -> Bool {
        let context = context()
        return try await context.perform {
            try Task.checkCancellation()
            guard let page = try Self.liveOCRPage(id: job.key.pageID, context: context),
                  page.value(forKey: "imageVersion") as? UUID == job.key.imageVersion else { return false }
            page.setValue(result.text, forKey: "rawOCRText")
            page.setValue(job.resultID, forKey: "ocrResultID")
            page.setValue(job.key.imageVersion, forKey: "ocrImageVersion")
            page.setValue("Apple Vision VNRecognizeTextRequest", forKey: "ocrEngine")
            page.setValue(String(result.revision), forKey: "ocrRevision")
            page.setValue(result.language, forKey: "ocrLanguage")
            page.setValue(Date(), forKey: "ocrDate")
            page.setValue(Int64(result.lowConfidenceLineCount), forKey: "ocrLowConfidenceLineCount")
            if job.selectsResult {
                page.setValue(nil, forKey: "selectedTranscriptRevisionID")
            }
            if page.value(forKey: "selectedTranscriptRevisionID") == nil {
                page.setValue(nil, forKey: "reviewedRevisionID")
            }
            page.setValue(Date(), forKey: "updatedAt")
            try context.save()
            return true
        }
    }

    nonisolated private static func liveOCRPage(id: UUID, context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalPage")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 2
        let pages = try context.fetch(request)
        guard pages.count <= 1 else { throw PersistenceError.invalidRecord }
        guard let page = pages.first, page.value(forKey: "deletedAt") == nil else { return nil }
        guard let entry = page.value(forKey: "entry") as? NSManagedObject else { throw PersistenceError.missingRecord }
        guard entry.value(forKey: "deletedAt") == nil else { return nil }
        guard entry.value(forKey: "pendingIngestionID") == nil else { throw PersistenceError.notLoaded }
        guard let notebook = entry.value(forKey: "notebook") as? NSManagedObject else { throw PersistenceError.missingRecord }
        guard notebook.value(forKey: "deletedAt") == nil else { return nil }
        guard page.value(forKey: "image") != nil else { throw PersistenceError.missingRecord }
        return page
    }
}
