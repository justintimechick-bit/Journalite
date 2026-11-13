import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

nonisolated enum ImportLimits {
    static let pages = 20
    static let imageBytes = 25 * 1_024 * 1_024
    static let totalBytes = 150 * 1_024 * 1_024
    static let pixels = 48_000_000
    static let thumbnailSide = 320
    static let displaySide = 2_048
    static let ocrSide = 3_072
}

nonisolated enum IngestionError: LocalizedError {
    case limit, invalidImage, io, empty, incomplete, notebook, conflict
    var errorDescription: String? {
        switch self {
        case .limit: "This image or import exceeds the limit: 20 pages, 25 MB per image, 150 MB total, and 48 megapixels per image. Try fewer or smaller still images."
        case .invalidImage: "This item could not be read as a supported still image. Try exporting it as a JPEG or PNG, then import again."
        case .io: "The image could not be staged or saved. Check free storage and try again. Any recovery receipt has been kept."
        case .empty: "Add at least one page before saving."
        case .incomplete: "Some pages are unavailable. Review the loaded pages and acknowledge the missing items before saving."
        case .notebook: "Choose a live notebook. For an interrupted save, restore its original notebook in Recently Deleted and retry."
        case .conflict: "The saved records do not match this receipt. Staged files were kept for recovery; no existing data was overwritten."
        }
    }
}

nonisolated struct ImageInfo: Sendable {
    let width: Int
    let height: Int
    let contentType: String
    let byteCount: Int
}

nonisolated enum ImageProcessing {
    static func inspect(_ url: URL) throws -> ImageInfo {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= ImportLimits.imageBytes else { throw IngestionError.limit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              let type = CGImageSourceGetType(source) else { throw IngestionError.invalidImage }
        guard width > 0, height > 0, width <= 16_000, height <= 16_000,
              width * height <= ImportLimits.pixels else { throw IngestionError.limit }
        return ImageInfo(width: width, height: height, contentType: type as String, byteCount: bytes)
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Only decoded pixels enter the destination; source GPS/EXIF dictionaries are never copied.
    @discardableResult
    static func derivative(source url: URL, destination: URL, maxSide: Int) throws -> Int {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary),
                  let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw IngestionError.invalidImage
            }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw IngestionError.io }
            return image.bytesPerRow * image.height
        }
    }
}
