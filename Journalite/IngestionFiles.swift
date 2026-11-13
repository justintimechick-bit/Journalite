import Foundation

nonisolated struct StagedPage: Codable, Identifiable, Sendable {
    let id: UUID
    let imageID: UUID
    let imageVersion: UUID
    let singleEntryID: UUID
    let sourceKind: String
    let hash: String
    let width: Int
    let height: Int
    let byteCount: Int
    let contentType: String
}

nonisolated struct IngestionReceipt: Codable, Identifiable, Sendable {
    enum Phase: String, Codable { case loading, review, saving, committed }
    let id: UUID
    let multipageEntryID: UUID
    let createdAt: Date
    var phase: Phase
    var expectedCount: Int
    var pages: [StagedPage]
    var failures: [String]
    var notebookID: UUID?
    var title: String
    var journalDate: Date
    var separateEntries: Bool
    var acknowledgedFailures: Bool

    var entryIDs: [UUID] { separateEntries ? pages.map(\.singleEntryID) : [multipageEntryID] }
}

/// Serial staging and derivative work; receipts are independent of the rebuildable image cache.
actor IngestionFiles {
    let root: URL

    init(root: URL) { self.root = root }

    func begin(count: Int, notebookID: UUID?) throws -> IngestionReceipt {
        guard count > 0, count <= ImportLimits.pages else { throw IngestionError.limit }
        let receipt = IngestionReceipt(id: UUID(), multipageEntryID: UUID(), createdAt: Date(),
            phase: .loading, expectedCount: count, pages: [], failures: [], notebookID: notebookID,
            title: "", journalDate: Date(), separateEntries: false, acknowledgedFailures: false)
        try persist(receipt)
        return receipt
    }

    func persist(_ receipt: IngestionReceipt) throws {
        let folder = directory(receipt.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("receipt.json")
        try JSONEncoder().encode(receipt).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try synchronize(url)
    }

    func recoverable() throws -> [IngestionReceipt] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try JSONDecoder().decode(IngestionReceipt.self, from: Data(contentsOf: $0.appendingPathComponent("receipt.json"))) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func stage(file: URL, into original: IngestionReceipt, sourceKind: String) throws -> IngestionReceipt {
        guard original.phase == .loading || original.phase == .review else { throw IngestionError.conflict }
        let info = try ImageProcessing.inspect(file)
        guard original.pages.count < ImportLimits.pages,
              original.pages.reduce(info.byteCount, { $0 + $1.byteCount }) <= ImportLimits.totalBytes else {
            throw IngestionError.limit
        }
        let page = StagedPage(id: UUID(), imageID: UUID(), imageVersion: UUID(), singleEntryID: UUID(),
            sourceKind: sourceKind, hash: try ImageProcessing.hash(file),
            width: info.width, height: info.height, byteCount: info.byteCount, contentType: info.contentType)
        let destination = sourceURL(receiptID: original.id, pageID: page.id)
        try FileManager.default.copyItem(at: file, to: destination)
        try synchronize(destination)
        _ = try ImageProcessing.derivative(source: destination, destination: thumbnailURL(receiptID: original.id, pageID: page.id), maxSide: ImportLimits.thumbnailSide)
        _ = try ImageProcessing.derivative(source: destination, destination: directory(original.id).appendingPathComponent(page.id.uuidString + ".display.jpg"), maxSide: ImportLimits.displaySide)
        _ = try ImageProcessing.derivative(source: destination, destination: directory(original.id).appendingPathComponent(page.id.uuidString + ".ocr.jpg"), maxSide: ImportLimits.ocrSide)
        var receipt = original
        receipt.pages.append(page)
        try persist(receipt)
        return receipt
    }

    func recordFailure(_ message: String, in original: IngestionReceipt) throws -> IngestionReceipt {
        var receipt = original
        receipt.failures.append(message)
        try persist(receipt)
        return receipt
    }

    func discard(_ receipt: IngestionReceipt) throws {
        guard receipt.phase == .review || receipt.phase == .loading else { throw IngestionError.conflict }
        try removeFolder(receipt.id)
    }

    func finish(_ receipt: IngestionReceipt) throws {
        var committed = receipt
        committed.phase = .committed
        try persist(committed)
        // Persist provenance before staged input can disappear. Retain only stable IDs and order.
        let ownership = OCROwnershipReceipt(id: receipt.id,
            pages: receipt.pages.map { OCRPageKey(pageID: $0.id, imageVersion: $0.imageVersion) },
            createdAt: receipt.createdAt)
        let archive = root.appendingPathComponent("OCRReceipts", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let url = archive.appendingPathComponent(receipt.id.uuidString + ".json")
        try JSONEncoder().encode(ownership).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try synchronize(url)
        try removeFolder(receipt.id)
    }

    func recordOwnership(keys: [OCRPageKey]) throws {
        guard !keys.isEmpty else { return }
        let ownership = OCROwnershipReceipt(id: UUID(), pages: keys, createdAt: Date())
        let archive = root.appendingPathComponent("OCRReceipts", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let url = archive.appendingPathComponent(ownership.id.uuidString + ".json")
        try JSONEncoder().encode(ownership).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try synchronize(url)
    }

    func ocrOwnership() throws -> [OCROwnershipReceipt] {
        var values = try recoverable().filter { $0.phase == .saving || $0.phase == .committed }.map { receipt in
            OCROwnershipReceipt(id: receipt.id,
                pages: receipt.pages.map { OCRPageKey(pageID: $0.id, imageVersion: $0.imageVersion) },
                createdAt: receipt.createdAt)
        }
        let archive = root.appendingPathComponent("OCRReceipts", isDirectory: true)
        if FileManager.default.fileExists(atPath: archive.path) {
            for file in try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil) {
                values.append(try JSONDecoder().decode(OCROwnershipReceipt.self, from: Data(contentsOf: file)))
            }
        }
        return values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func sourceURL(receiptID: UUID, pageID: UUID) -> URL {
        directory(receiptID).appendingPathComponent(pageID.uuidString + ".source")
    }
    func thumbnailURL(receiptID: UUID, pageID: UUID) -> URL {
        directory(receiptID).appendingPathComponent(pageID.uuidString + ".thumb.jpg")
    }

    private func synchronize(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    private func removeFolder(_ id: UUID) throws {
        let folder = directory(id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}
