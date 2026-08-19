import Foundation

/// Identity and failure vocabulary for unpacking an extension package.
///
/// Kept from the retired ExtensionKit runtime because CRX3 install (M4) still has to unpack
/// a signed archive to a directory before `WKWebExtension(resourceBaseURL:)` can read it.
/// Nothing here parses a manifest — that is WebKit's job under ADR-001.
public struct ExtensionIdentifier: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 32,
              rawValue.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum ExtensionInstallError: LocalizedError, Equatable, Sendable {
    case archiveTooLarge(limit: UInt64)
    case archiveUnreadable
    case tooManyEntries(limit: Int)
    case entryTooLarge(path: String, limit: UInt64)
    case expandedArchiveTooLarge(limit: UInt64)
    case tooManyInstalledExtensions(limit: Int)
    case invalidEntryPath(String)
    case duplicateEntryPath(String)
    case symbolicLinkNotAllowed(String)
    case unsupportedEntry(String)
    case nativeBinaryNotAllowed(String)
    case suspiciousCompressionRatio(String)
    case checksumMismatch(String)
    case extractionFailed(path: String)
    case packageAlreadyInstalled(String)
    case identifierCollision(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .archiveTooLarge(let limit):
            return "The ZIP archive exceeds the \(limit) byte limit."
        case .archiveUnreadable:
            return "The selected item is not a readable ZIP archive or extension folder."
        case .tooManyEntries(let limit):
            return "The extension package contains more than \(limit) entries."
        case .entryTooLarge(let path, let limit):
            return "'\(path)' exceeds the \(limit) byte per-file limit."
        case .expandedArchiveTooLarge(let limit):
            return "The extracted extension exceeds the \(limit) byte limit."
        case .tooManyInstalledExtensions(let limit):
            return "No more than \(limit) extensions can be installed. Remove one and try again."
        case .invalidEntryPath(let path):
            return "The extension package contains an unsafe path: \(path)"
        case .duplicateEntryPath(let path):
            return "The extension package contains a duplicate path: \(path)"
        case .symbolicLinkNotAllowed(let path):
            return "Symbolic links are not allowed in extensions: \(path)"
        case .unsupportedEntry(let path):
            return "The ZIP entry type or compression is unsupported: \(path)"
        case .nativeBinaryNotAllowed(let path):
            return "Native executable content is not allowed: \(path)"
        case .suspiciousCompressionRatio(let path):
            return "The ZIP entry has an unsafe compression ratio: \(path)"
        case .checksumMismatch(let path):
            return "ZIP checksum validation failed for: \(path)"
        case .extractionFailed(let path):
            return "The ZIP entry could not be extracted: \(path)"
        case .packageAlreadyInstalled(let identifier):
            return "Extension \(identifier) is already installed."
        case .identifierCollision(let identifier):
            return "A different package already uses extension identifier \(identifier)."
        case .cancelled:
            return "Extension import was cancelled."
        }
    }
}

