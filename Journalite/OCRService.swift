import Foundation

/// Actor-isolated orchestration and ImageIO work. Recognition goes through `TranscriptionPipeline`:
/// the on-device language model when available, otherwise Vision on a detached utility task.
actor OCRService {
    let queue: OCRQueue
    private let recognizer: any OCRRecognizing
    private let scratch: URL
    private var running = false

    init(queue: OCRQueue, recognizer: any OCRRecognizing = TranscriptionPipeline(), scratch: URL) {
        self.queue = queue
        self.recognizer = recognizer
        self.scratch = scratch
    }

    func reconcile(files: IngestionFiles, repository: JournalRepository, language: String) async throws {
        try await queue.load()
        for receipt in try await files.ocrOwnership() {
            for key in receipt.pages {
                // Receipt is proof of local capture. Missing OCR alone is never proof of ownership.
                // Pending ingestion remains ineligible until its full durable save is completed.
                do {
                    if let page = try await repository.ocrPage(id: key.pageID),
                       page.key == key, page.resultID == nil {
                        try await queue.enqueue([key], language: language)
                    }
                } catch PersistenceError.notLoaded { continue }
            }
        }
    }

    func run(repository: JournalRepository,
             changed: @escaping @Sendable () async -> Void) async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Dedicated disposable directory; remove only OCR derivatives/source copies, never the store.
        for file in try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        while !Task.isCancelled, let job = try await queue.next() {
            try await queue.transition(job, to: .running)
            await changed()
            do {
                guard let page = try await repository.ocrPage(id: job.key.pageID), page.key == job.key else {
                    try await queue.transition(job, to: .cancelled)
                    await changed()
                    continue
                }
                // A crash after Core Data save but before queue acknowledgement must not redo OCR.
                if page.resultID == job.resultID {
                    try await queue.transition(job, to: .completed)
                    await changed()
                    continue
                }
                let source = scratch.appendingPathComponent(job.resultID.uuidString + ".source")
                let input = scratch.appendingPathComponent(job.resultID.uuidString + ".jpg")
                defer {
                    try? FileManager.default.removeItem(at: source)
                    try? FileManager.default.removeItem(at: input)
                }
                try await repository.writeSource(pageID: job.key.pageID, to: source)
                try Task.checkCancellation()
                try ImageProcessing.derivative(source: source, destination: input, maxSide: ImportLimits.ocrSide)
                try Task.checkCancellation()
                let result = try await recognizer.recognize(image: input, language: job.language)
                try Task.checkCancellation()
                let current = try await queue.snapshot().first { $0.key == job.key }
                guard current?.state == .running, current?.resultID == job.resultID else { continue }
                let saved = try await repository.saveOCR(result, job: job)
                try await queue.transition(job, to: saved ? .completed : .cancelled)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    try await queue.transition(job, to: .waiting)
                    await changed()
                    return
                }
                try await queue.transition(job, to: .failed)
                // Recoverable errors require an explicit retry; no timer or automatic busy loop.
            }
            await changed()
        }
    }
}
