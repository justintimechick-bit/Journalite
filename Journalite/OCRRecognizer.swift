import Foundation
import Vision
import ImageIO

nonisolated struct OCRLine: Sendable {
    let text: String
    let confidence: Float
    let box: CGRect
}

nonisolated struct OCRResult: Sendable {
    let text: String
    let revision: Int
    let language: String
    let lowConfidenceLineCount: Int

    /// Ordinary horizontal, single-column pages: group fragments on the same baseline,
    /// then join rows from top to bottom. This is not a general layout parser.
    static func assemble(_ observations: [OCRLine], revision: Int, language: String) -> OCRResult {
        let sorted = observations.sorted {
            $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY > $1.box.midY
        }
        var rows: [[OCRLine]] = []
        for line in sorted {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.box.midY - line.box.midY) <= min(anchor.box.height, line.box.height) * 0.45 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        let text = rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
        return OCRResult(text: text, revision: revision, language: language,
                         lowConfidenceLineCount: observations.filter { $0.confidence < 0.5 }.count)
    }
}

nonisolated protocol OCRRecognizing: Sendable {
    func recognize(image: URL, language: String) async throws -> OCRResult
}

nonisolated enum OCRError: Error { case unsupportedLanguage, unavailable }

/// The lock protects cancellation/installation only. Vision execution stays on one detached task.
nonisolated private final class VisionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false

    func install(_ value: VNRecognizeTextRequest) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        request = value
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let value = request
        lock.unlock()
        value?.cancel()
    }
}

nonisolated struct VisionOCRRecognizer: OCRRecognizing {
    static func supportedLanguages() async throws -> [String] {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            return try request.supportedRecognitionLanguages().sorted()
        }.value
    }

    func recognize(image: URL, language: String) async throws -> OCRResult {
        let cancellation = VisionCancellation()
        return try await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) {
                try autoreleasepool {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    guard try request.supportedRecognitionLanguages().contains(language) else {
                        throw OCRError.unsupportedLanguage
                    }
                    request.recognitionLanguages = [language]
                    request.automaticallyDetectsLanguage = false
                    request.usesLanguageCorrection = false
                    try cancellation.install(request)
                    // ImageIO already baked EXIF orientation into the derivative's pixels.
                    try VNImageRequestHandler(url: image, orientation: .up).perform([request])
                    let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return OCRLine(text: candidate.string, confidence: candidate.confidence,
                                       box: observation.boundingBox)
                    }
                    return OCRResult.assemble(lines, revision: request.revision, language: language)
                }
            }
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }
}
