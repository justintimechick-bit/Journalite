import Foundation

actor JournalImageCache {
    static let shared = JournalImageCache()
    private let root = URL.cachesDirectory.appendingPathComponent("JournaliteImages", isDirectory: true)

    enum Kind: String, Sendable {
        case thumbnail, display, ocr, share
        nonisolated var side: Int {
            switch self {
            case .thumbnail: ImportLimits.thumbnailSide
            case .display, .share: ImportLimits.displaySide
            case .ocr: ImportLimits.ocrSide
            }
        }
    }

    func image(pageID: UUID, repository: JournalRepository, kind: Kind) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Source images are immutable. UUIDs are never reused, so page UUID is a stable cache key.
        let output = root.appendingPathComponent(pageID.uuidString + "-" + kind.rawValue + ".jpg")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let source = root.appendingPathComponent(UUID().uuidString + ".source")
        defer { try? FileManager.default.removeItem(at: source) }
        try await repository.writeSource(pageID: pageID, to: source)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        _ = try ImageProcessing.derivative(source: source, destination: output, maxSide: kind.side)
        try prune(except: output)
        return output
    }

    func adopt(_ receipt: IngestionReceipt, directory: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for page in receipt.pages {
            for (suffix, kind) in [("thumb", Kind.thumbnail), ("display", .display), ("ocr", .ocr)] {
                let input = directory.appendingPathComponent(page.id.uuidString + "." + suffix + ".jpg")
                let output = root.appendingPathComponent(page.id.uuidString + "-" + kind.rawValue + ".jpg")
                if !FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.copyItem(at: input, to: output)
                }
                try prune(except: output)
            }
        }
    }

    private func prune(except keep: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "jpg" }
        let sorted = try files.map { ($0, try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var total = sorted.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        for (url, values) in sorted where total > 256 * 1_024 * 1_024 && url != keep {
            try FileManager.default.removeItem(at: url)
            total -= values.fileSize ?? 0
        }
    }
}
