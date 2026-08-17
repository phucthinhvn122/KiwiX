import Foundation
import ImageIO

struct FaviconImageMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
}

struct FaviconDecodedImage: @unchecked Sendable {
    let cgImage: CGImage
}

enum FaviconValidationError: Error, Equatable {
    case emptyData
    case responseTooLarge
    case unsupportedMIMEType
    case unrecognizedImage
    case invalidDimensions
}

enum FaviconImageValidator {
    static let maximumEncodedByteCount = 1_500_000
    static let maximumDimension = 1_024
    static let maximumPixelCount = 1_048_576
    static let renderedMaximumDimension = 128

    private static let allowedMIMETypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
        "image/x-icon",
        "image/vnd.microsoft.icon",
        "application/octet-stream"
    ]

    static func validate(data: Data, responseMIMEType: String?) throws -> FaviconImageMetadata {
        guard !data.isEmpty else { throw FaviconValidationError.emptyData }
        guard data.count <= maximumEncodedByteCount else { throw FaviconValidationError.responseTooLarge }

        if let responseMIMEType {
            let normalized = responseMIMEType.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard allowedMIMETypes.contains(normalized) else {
                throw FaviconValidationError.unsupportedMIMEType
            }
        }
        guard hasRecognizedRasterSignature(data) else {
            throw FaviconValidationError.unrecognizedImage
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              width <= maximumPixelCount / height else {
            throw FaviconValidationError.invalidDimensions
        }
        return FaviconImageMetadata(pixelWidth: width, pixelHeight: height)
    }

    static func downsampledImage(from data: Data) -> FaviconDecodedImage? {
        guard (try? validate(data: data, responseMIMEType: nil)) != nil,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: renderedMaximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return FaviconDecodedImage(cgImage: image)
    }

    private static func hasRecognizedRasterSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return true }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }
        return bytes.count >= 12 &&
            Array(bytes[0..<4]) == Array("RIFF".utf8) &&
            Array(bytes[8..<12]) == Array("WEBP".utf8)
    }
}

actor FaviconImageDecoder {
    func decode(_ data: Data) -> FaviconDecodedImage? {
        FaviconImageValidator.downsampledImage(from: data)
    }
}
