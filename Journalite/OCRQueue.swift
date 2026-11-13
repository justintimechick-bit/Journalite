import Foundation

nonisolated struct OCRPageKey: Codable, Hashable, Sendable {
    let pageID: UUID
    let imageVersion: UUID
}

nonisolated struct OCROwnershipReceipt: Codable, Sendable {
    let id: UUID
    let pages: [OCRPageKey]
    let createdAt: Date
}

nonisolated struct OCRJob: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case waiting, running, completed, failed, cancelled }
    let key: OCRPageKey
    var resultID: UUID
    var language: String
    var state: State
    /// Set by an explicit Retry OCR. The result becomes the displayed transcription even when a
    /// manual revision is selected; manual revisions stay in history and can be restored.
    var selectsResult = false

    private enum CodingKeys: String, CodingKey { case key, resultID, language, state, selectsResult }
}

extension OCRJob {
    // Queues written before `selectsResult` existed must still decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(OCRPageKey.self, forKey: .key),
                  resultID: try container.decode(UUID.self, forKey: .resultID),
                  language: try container.decode(String.self, forKey: .language),
                  state: try container.decode(State.self, forKey: .state),
                  selectsResult: try container.decodeIfPresent(Bool.self, forKey: .selectsResult) ?? false)
    }
}

/// Device-local execution state. No journal text or photo bytes; never a CloudKit entity.
actor OCRQueue {
    private let url: URL
    private var jobs: [OCRJob] = []
    private var loaded = false

    init(url: URL) { self.url = url }

    func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            jobs = try JSONDecoder().decode([OCRJob].self, from: Data(contentsOf: url))
        }
        for i in jobs.indices where jobs[i].state == .running { jobs[i].state = .waiting }
        try persist(jobs)
        loaded = true
    }

    func snapshot() throws -> [OCRJob] {
        try load()
        return jobs
    }

    func enqueue(_ keys: [OCRPageKey], language: String, retry: Bool = false) throws {
        try load()
        var next = jobs
        for key in keys {
            if let i = next.firstIndex(where: { $0.key == key }) {
                if retry && next[i].state != .running {
                    next[i].state = .waiting
                    next[i].language = language
                    next[i].resultID = UUID()
                    next[i].selectsResult = true
                }
            } else {
                next.append(OCRJob(key: key, resultID: UUID(), language: language, state: .waiting, selectsResult: retry))
            }
        }
        try persist(next)
        jobs = next
    }

    func next() throws -> OCRJob? {
        try load()
        return jobs.first { $0.state == .waiting }
    }

    func transition(_ job: OCRJob, to state: OCRJob.State) throws {
        try load()
        guard let i = jobs.firstIndex(where: { $0.key == job.key && $0.resultID == job.resultID }),
              jobs[i].state != .cancelled else { return }
        var next = jobs
        next[i].state = state
        try persist(next)
        jobs = next
    }

    func cancel(_ key: OCRPageKey) throws {
        try load()
        guard let i = jobs.firstIndex(where: { $0.key == key }) else { return }
        var next = jobs
        next[i].state = .cancelled
        try persist(next)
        jobs = next
    }

    private func persist(_ values: [OCRJob]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }
}
