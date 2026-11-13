import CoreData
import Foundation
import Testing
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Journalite

nonisolated private struct MockRecognizer: OCRRecognizing {
    let action: @Sendable () async throws -> OCRResult
    func recognize(image: URL, language: String) async throws -> OCRResult { try await action() }
}

private actor RecognitionGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func hasStarted() -> Bool { started }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class OCRFixture {
    let root: URL
    let persistence: PersistenceController
    let repository: JournalRepository
    let files: IngestionFiles
    let queue: OCRQueue
    let notebookID: UUID

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        persistence = PersistenceController(location: .sqlite(root.appendingPathComponent("Journal.sqlite")))
        try await persistence.load()
        repository = try persistence.repository()
        notebookID = try await repository.createNotebook(name: "Test notebook")
        files = IngestionFiles(root: root.appendingPathComponent("Ingestion"))
        queue = OCRQueue(url: root.appendingPathComponent("queue.json"))
    }

    func receipt(count: Int = 1) async throws -> IngestionReceipt {
        let image = try Self.image(at: root.appendingPathComponent("fixture.png"))
        var receipt = try await files.begin(count: count, notebookID: notebookID)
        for _ in 0..<count {
            receipt = try await files.stage(file: image, into: receipt, sourceKind: "photoImport")
        }
        receipt.phase = .saving
        try await files.persist(receipt)
        try await repository.commit(receipt, directory: files.directory(receipt.id))
        return receipt
    }

    func service(_ action: @escaping @Sendable () async throws -> OCRResult) -> OCRService {
        OCRService(queue: queue, recognizer: MockRecognizer(action: action), scratch: root.appendingPathComponent("Scratch"))
    }

    func close() throws {
        try persistence.close()
        try FileManager.default.removeItem(at: root)
    }

    static func image(at url: URL, text: String = "", orientation: Int = 1) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1600), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
            (text as NSString).draw(in: CGRect(x: 100, y: 140, width: 1000, height: 1300),
                withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
        }
        let cgImage = try #require(image.cgImage)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

@MainActor
struct OCRTests {
    private static let empty = OCRResult(text: "", revision: 3, language: "en-US", lowConfidenceLineCount: 0)

    @Test func receiptRecoveryPreservesOrderAndSourceBytesWithoutScanningAllPages() async throws {
        let f = try await OCRFixture()
        defer { try? f.close() }
        let receipt = try await f.receipt(count: 3)
        // An unrelated saved record is not local OCR ownership evidence.
        let bytes = try Data(contentsOf: f.root.appendingPathComponent("fixture.png"))
        let other = try await f.repository.createEntry(notebookID: f.notebookID, title: "", journalDate: Date(),
            pages: [PageDraft(sourceData: bytes, contentType: "image/jpeg", pixelWidth: 1200, pixelHeight: 1600, sourceKind: "photoImport", sourceHash: nil)])
        let service = f.service { Self.empty }
        try await service.reconcile(files: f.files, repository: f.repository, language: "en-US")
        #expect(try await f.queue.snapshot().map(\.key.pageID) == receipt.pages.map(\.id))
        try await f.files.finish(receipt)
        #expect(try await f.files.recoverable().isEmpty)
        // Loss of queue can be reconciled from retained local receipt IDs, not missing OCR.
        let secondQueue = OCRQueue(url: f.root.appendingPathComponent("second-queue.json"))
        let recovered = OCRService(queue: secondQueue, recognizer: MockRecognizer { Self.empty }, scratch: f.root.appendingPathComponent("OtherScratch"))
        try await recovered.reconcile(files: f.files, repository: f.repository, language: "en-US")
        #expect(try await secondQueue.snapshot().map(\.key.pageID) == receipt.pages.map(\.id))
        try await recovered.run(repository: f.repository, changed: {})
        for page in receipt.pages {
            let snapshot = try #require(try await f.repository.ocrPage(id: page.id))
            #expect(snapshot.rawText == "")
            #expect(snapshot.resultID != nil)
            let copy = f.root.appendingPathComponent(page.id.uuidString)
            try await f.repository.writeSource(pageID: page.id, to: copy)
            #expect(try Data(contentsOf: copy) == bytes)
        }
        let unrelated = try #require(try await f.repository.pages(entryID: other).first)
        #expect(try await f.repository.ocrPage(id: unrelated.id)?.resultID == nil)
        try f.persistence.close()
        let reopened = PersistenceController(location: .sqlite(f.root.appendingPathComponent("Journal.sqlite")))
        try await reopened.load()
        #expect(try await reopened.repository().ocrPage(id: receipt.pages[0].id)?.rawText == "")
        try reopened.close()
    }

    @Test func runningQueueRecoversAndAcknowledgesAlreadySavedResult() async throws {
        let f = try await OCRFixture()
        defer { try? f.close() }
        let receipt = try await f.receipt()
        let key = OCRPageKey(pageID: receipt.pages[0].id, imageVersion: receipt.pages[0].imageVersion)
        try await f.queue.enqueue([key], language: "en-US")
        let job = try #require(try await f.queue.next())
        try await f.queue.transition(job, to: .running)
        #expect(try await f.repository.saveOCR(Self.empty, job: job))
        let reopenedQueue = OCRQueue(url: f.root.appendingPathComponent("queue.json"))
        #expect(try await reopenedQueue.next()?.state == .waiting)
        let service = OCRService(queue: reopenedQueue, recognizer: MockRecognizer {
            Issue.record("Committed OCR must not run again after a crash")
            return Self.empty
        }, scratch: f.root.appendingPathComponent("Scratch"))
        try await service.run(repository: f.repository, changed: {})
        #expect(try await reopenedQueue.snapshot().first?.state == .completed)
        #expect(try await f.repository.ocrPage(id: key.pageID)?.resultID == job.resultID)
    }

    @Test func automaticOCRKeepsSelectedManualRevision() async throws {
        let f = try await OCRFixture()
        defer { try? f.close() }
        let receipt = try await f.receipt()
        let key = OCRPageKey(pageID: receipt.pages[0].id, imageVersion: receipt.pages[0].imageVersion)
        _ = try await f.repository.appendCorrection(pageID: key.pageID, text: "Hand corrected")
        try await f.queue.enqueue([key], language: "en-US")
        let service = f.service { OCRResult(text: "Recognized fixture", revision: 3, language: "en-US", lowConfidenceLineCount: 0) }
        try await service.run(repository: f.repository, changed: {})
        let page = try #require(try await f.repository.ocrPage(id: key.pageID))
        #expect(page.rawText == "Recognized fixture")
        #expect(page.text == "Hand corrected")
    }

    @Test func queueWithoutSelectsResultFieldStillDecodes() throws {
        let json = #"[{"state":"completed","key":{"pageID":"F53E8CFD-6310-4940-9177-76EB64C9E4AA","imageVersion":"B4606961-6501-4148-AEF7-E1339B102864"},"resultID":"57F782E5-1A33-415E-859F-E7F6A9B7FB3D","language":"en-US"}]"#
        let jobs = try JSONDecoder().decode([OCRJob].self, from: Data(json.utf8))
        #expect(jobs.first?.selectsResult == false)
    }

    @Test func explicitRetryReplacesSelectedManualRevisionAndFailureRequiresExplicitRetry() async throws {
        let f = try await OCRFixture()
        defer { try? f.close() }
        let receipt = try await f.receipt()
        let key = OCRPageKey(pageID: receipt.pages[0].id, imageVersion: receipt.pages[0].imageVersion)
        let revision = try await f.repository.appendCorrection(pageID: key.pageID, text: "")
        try await f.queue.enqueue([key], language: "en-US")
        let failing = f.service { throw OCRError.unavailable }
        try await failing.run(repository: f.repository, changed: {})
        #expect(try await f.queue.snapshot().first?.state == .failed)
        #expect(try await f.queue.next() == nil)
        let oldID = try #require(try await f.queue.snapshot().first?.resultID)
        try await f.queue.enqueue([key], language: "en-US", retry: true)
        let service = f.service { OCRResult(text: "Recognized fixture", revision: 3, language: "en-US", lowConfidenceLineCount: 1) }
        try await service.run(repository: f.repository, changed: {})
        let page = try #require(try await f.repository.ocrPage(id: key.pageID))
        #expect(page.resultID != oldID)
        #expect(page.rawText == "Recognized fixture")
        // Explicit retry makes the new OCR current; the manual revision stays in history.
        #expect(page.text == "Recognized fixture")
        #expect(page.lowConfidenceLineCount == 1)
        let context = try #require(f.persistence.container).newBackgroundContext()
        try await context.perform {
            let object = try JournalRepository.find("JournalPage", id: key.pageID, in: context)
            #expect(object.value(forKey: "selectedTranscriptRevisionID") == nil)
            let revisions = object.value(forKey: "transcriptRevisions") as? Set<NSManagedObject> ?? []
            #expect(revisions.contains { $0.value(forKey: "id") as? UUID == revision })
            #expect(object.value(forKey: "ocrImageVersion") as? UUID == key.imageVersion)
            #expect(object.value(forKey: "ocrEngine") as? String == "Apple Vision VNRecognizeTextRequest")
            #expect(object.value(forKey: "ocrRevision") as? String == "3")
            #expect(object.value(forKey: "ocrDate") as? Date != nil)
        }
    }

    @Test func cancelledDeletedAndStalePagesDoNotReceiveResults() async throws {
        let f = try await OCRFixture()
        defer { try? f.close() }
        let receipt = try await f.receipt(count: 3)
        let keys = receipt.pages.map { OCRPageKey(pageID: $0.id, imageVersion: $0.imageVersion) }
        try await f.queue.enqueue(keys, language: "en-US")
        try await f.queue.cancel(keys[0])
        let context = try #require(f.persistence.container).newBackgroundContext()
        try await context.perform {
            let deleted = try JournalRepository.find("JournalPage", id: keys[1].pageID, in: context)
            deleted.setValue(Date(), forKey: "deletedAt")
            let stale = try JournalRepository.find("JournalPage", id: keys[2].pageID, in: context)
            stale.setValue(UUID(), forKey: "imageVersion")
            try context.save()
        }
        let service = f.service {
            Issue.record("Cancelled, deleted and stale jobs must not recognize")
            return Self.empty
        }
        try await service.run(repository: f.repository, changed: {})
        #expect(try await f.queue.snapshot().allSatisfy { $0.state == .cancelled })
        let staleJob = OCRJob(key: keys[2], resultID: UUID(), language: "en-US", state: .running)
        #expect(try await f.repository.saveOCR(Self.empty, job: staleJob) == false)
        #expect(try await f.repository.ocrPage(id: keys[0].pageID)?.resultID == nil)
    }

    @Test func pauseCancelsInFlightWorkAndResumeIsSequential() async throws {
        let f = try await OCRFixture()
        defer { try? f.close() }
        let receipt = try await f.receipt(count: 2)
        let keys = receipt.pages.map { OCRPageKey(pageID: $0.id, imageVersion: $0.imageVersion) }
        try await f.queue.enqueue(keys, language: "en-US")
        let gate = RecognitionGate()
        let service = f.service {
            await gate.wait()
            return Self.empty
        }
        let task = Task { try await service.run(repository: f.repository, changed: {}) }
        for _ in 0..<200 {
            if await gate.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasStarted())
        let running = try await f.queue.snapshot()
        #expect(running.map(\.state) == [.running, .waiting])
        task.cancel()
        await gate.release()
        try await task.value
        #expect(try await f.queue.snapshot().map(\.state) == [.waiting, .waiting])
        #expect(try await f.repository.ocrPage(id: keys[0].pageID)?.resultID == nil)
        let resume = f.service { Self.empty }
        try await resume.run(repository: f.repository, changed: {})
        #expect(try await f.queue.snapshot().allSatisfy { $0.state == .completed })
    }

    @Test(arguments: ["cancel", "delete", "replace"])
    func inFlightResultCannotReviveCancelledDeletedOrReplacedPage(change: String) async throws {
        let f = try await OCRFixture()
        defer { try? f.close() }
        let receipt = try await f.receipt()
        let key = OCRPageKey(pageID: receipt.pages[0].id, imageVersion: receipt.pages[0].imageVersion)
        try await f.queue.enqueue([key], language: "en-US")
        let gate = RecognitionGate()
        let service = f.service {
            await gate.wait()
            return OCRResult(text: "Obsolete fixture", revision: 3, language: "en-US", lowConfidenceLineCount: 0)
        }
        let task = Task { try await service.run(repository: f.repository, changed: {}) }
        for _ in 0..<200 {
            if await gate.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasStarted())
        if change == "cancel" {
            try await f.queue.cancel(key)
        } else {
            let context = try #require(f.persistence.container).newBackgroundContext()
            try await context.perform {
                let page = try JournalRepository.find("JournalPage", id: key.pageID, in: context)
                if change == "delete" { page.setValue(Date(), forKey: "deletedAt") }
                else { page.setValue(UUID(), forKey: "imageVersion") }
                try context.save()
            }
        }
        await gate.release()
        try await task.value
        #expect(try await f.queue.snapshot().first?.state == .cancelled)
        let context = try #require(f.persistence.container).newBackgroundContext()
        try await context.perform {
            let page = try JournalRepository.find("JournalPage", id: key.pageID, in: context)
            #expect(page.value(forKey: "ocrResultID") == nil)
            #expect(page.value(forKey: "rawOCRText") == nil)
        }
    }

    @Test func partialIngestionRecoveryWaitsForDurableSaveAndCancellationCreatesNoRecords() async throws {
        let f = try await OCRFixture()
        defer { try? f.close() }
        let image = try OCRFixture.image(at: f.root.appendingPathComponent("original.jpg"))
        var cancelled = try await f.files.begin(count: 2, notebookID: f.notebookID)
        cancelled = try await f.files.stage(file: image, into: cancelled, sourceKind: "photoImport")
        let bad = f.root.appendingPathComponent("invalid.jpg")
        try Data([0, 1, 2]).write(to: bad)
        do {
            _ = try await f.files.stage(file: bad, into: cancelled, sourceKind: "photoImport")
            Issue.record("Invalid selected item must not be accepted")
        } catch {
            cancelled = try await f.files.recordFailure("Photo 2 could not load", in: cancelled)
        }
        #expect(cancelled.pages.count == 1)
        #expect(cancelled.failures.count == 1)
        try await f.files.discard(cancelled)
        #expect(try await f.repository.entries().entries.isEmpty)

        var receipt = try await f.files.begin(count: 2, notebookID: f.notebookID)
        for _ in 0..<2 { receipt = try await f.files.stage(file: image, into: receipt, sourceKind: "photoImport") }
        receipt.phase = .saving
        try await f.files.persist(receipt)
        let directory = await f.files.directory(receipt.id)
        let second = await f.files.sourceURL(receiptID: receipt.id, pageID: receipt.pages[1].id)
        let moved = f.root.appendingPathComponent("temporarily-unavailable.source")
        try FileManager.default.moveItem(at: second, to: moved)
        do {
            try await f.repository.commit(receipt, directory: directory)
            Issue.record("Incomplete save must retain pending state")
        } catch {}
        #expect(try await f.repository.entries().entries.isEmpty)
        let service = f.service { Self.empty }
        try await service.reconcile(files: f.files, repository: f.repository, language: "en-US")
        #expect(try await f.queue.snapshot().isEmpty)
        #expect(try await f.files.recoverable().count == 1)
        try FileManager.default.moveItem(at: moved, to: second)
        try await f.repository.commit(receipt, directory: directory)
        try await service.reconcile(files: f.files, repository: f.repository, language: "en-US")
        #expect(try await f.queue.snapshot().map(\.key.pageID) == receipt.pages.map(\.id))
        try await f.repository.commit(receipt, directory: directory)
        #expect(try await f.repository.pages(entryID: receipt.multipageEntryID).map(\.id) == receipt.pages.map(\.id))
        try f.persistence.close()
        let reopened = PersistenceController(location: .sqlite(f.root.appendingPathComponent("Journal.sqlite")))
        try await reopened.load()
        let copy = f.root.appendingPathComponent("reopened.jpg")
        try await reopened.repository().writeSource(pageID: receipt.pages[1].id, to: copy)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: image))
        try reopened.close()
    }

    @Test func deniedCameraPolicyKeepsImportAvailableWithoutRequestingOnLaunch() {
        #expect(CameraDecision.resolve(supported: true, authorized: false, notDetermined: false) == .denied)
        #expect(CameraDecision.resolve(supported: false, authorized: false, notDetermined: true) == .unsupported)
        #expect(CameraDecision.resolve(supported: true, authorized: false, notDetermined: true) == .request)
    }

    @Test func unreadableQueueIsPreservedForRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let original = Data("Invalid queue fixture".utf8)
        try original.write(to: url)
        let queue = OCRQueue(url: url)
        do {
            try await queue.load()
            Issue.record("Invalid queue must fail without resetting")
        } catch {
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func geometryPreservesOrdinaryLineOrder() {
        let lines = [
            OCRLine(text: "Last line", confidence: 1, box: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.06)),
            OCRLine(text: "reference", confidence: 0.3, box: CGRect(x: 0.5, y: 0.8, width: 0.3, height: 0.06)),
            OCRLine(text: "Bible", confidence: 1, box: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.06))
        ]
        let result = OCRResult.assemble(lines, revision: 3, language: "en-US")
        #expect(result.text == "Bible reference\nLast line")
        #expect(result.lowConfidenceLineCount == 1)
    }

    @Test(arguments: ["JournalModelV1", "JournalModelV2"])
    func oldSQLiteMigratesWithoutDiscardingExistingPages(version: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try #require(Bundle.main.url(forResource: "JournalModel", withExtension: "momd"))
        let model = try #require(NSManagedObjectModel(contentsOf: bundle.appendingPathComponent(version + ".mom")))
        let container = NSPersistentContainer(name: "Legacy", managedObjectModel: model)
        let url = root.appendingPathComponent("Legacy.sqlite")
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let repository = JournalRepository(container: container)
        let notebook = try await repository.createNotebook(name: "Preserved")
        let entry = try await repository.createEntry(notebookID: notebook, title: "Legacy", journalDate: Date(),
            pages: [PageDraft(sourceData: Data([1, 2, 3]), contentType: "image/jpeg", pixelWidth: 1, pixelHeight: 1, sourceKind: "import", sourceHash: nil)])
        let page = try #require(try await repository.pages(entryID: entry).first)
        _ = try await repository.appendCorrection(pageID: page.id, text: "")
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        let current = PersistenceController(location: .sqlite(url))
        try await current.load()
        #expect(try await current.repository().pages(entryID: entry).first?.id == page.id)
        #expect(try await current.repository().ocrPage(id: page.id)?.text == "")
        #expect(current.container?.managedObjectModel.entitiesByName["JournalPage"]?.attributesByName["ocrImageVersion"] != nil)
        try current.close()
    }
}

/// Executes actual Vision, separate from deterministic queue tests. Generated fixtures are not handwriting evidence.
@MainActor
struct VisionIntegrationTests {
    @Test func realVisionPrintedJournalAndBlankPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let languages = try await VisionOCRRecognizer.supportedLanguages()
        #expect(languages.contains("en-US"))
        let recognizer = VisionOCRRecognizer()
        let original = try OCRFixture.image(at: root.appendingPathComponent("journal.jpg"),
            text: "Journal Notes\nFamily memories\n1 Corinthians 13:4\nLove is patient.")
        let input = root.appendingPathComponent("input.jpg")
        let rasterBytes = try ImageProcessing.derivative(source: original, destination: input, maxSide: ImportLimits.ocrSide)
        #expect(rasterBytes <= ImportLimits.ocrSide * ImportLimits.ocrSide * 4)
        let result = try await recognizer.recognize(image: input, language: "en-US")
        #expect(result.text.contains("Family"))
        #expect(result.text.contains("Corinthians"))
        #expect(result.text.contains("\n"))
        let blank = try OCRFixture.image(at: root.appendingPathComponent("blank.jpg"))
        let noText = try await recognizer.recognize(image: blank, language: "en-US")
        #expect(noText.text == "")
        let rotated = try OCRFixture.image(at: root.appendingPathComponent("rotated.jpg"), orientation: 6)
        let rotatedInput = root.appendingPathComponent("upright.jpg")
        try ImageProcessing.derivative(source: rotated, destination: rotatedInput, maxSide: ImportLimits.ocrSide)
        let source = try #require(CGImageSourceCreateWithURL(rotatedInput as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1600)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1200)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    }
}
