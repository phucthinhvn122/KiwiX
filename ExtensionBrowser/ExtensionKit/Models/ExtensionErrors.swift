import Foundation

public enum ExtensionManifestError: LocalizedError, Equatable, Sendable {
    case unreadableManifest
    case invalidJSON(String)
    case manifestLimitExceeded(String)
    case unsupportedManifestVersion(Int)
    case missingName
    case invalidVersion(String)
    case missingContentScriptMatches(index: Int)
    case contentScriptLimitExceeded(String)
    case invalidMatchPattern(pattern: String, reason: String)
    case unsafeResourcePath(String)
    case unsupportedPermission(String)
    case multipleManifests
    case manifestNotFound

    public var errorDescription: String? {
        switch self {
        case .unreadableManifest:
            return "manifest.json could not be read."
        case .invalidJSON(let details):
            return "manifest.json is invalid: \(details)"
        case .manifestLimitExceeded(let details):
            return "manifest.json exceeds a safety limit: \(details)"
        case .unsupportedManifestVersion(let version):
            return "Manifest version \(version) is unsupported. Only Manifest V3 is accepted."
        case .missingName:
            return "The extension name is missing."
        case .invalidVersion(let version):
            return "The extension version '\(version)' is invalid."
        case .missingContentScriptMatches(let index):
            return "Content script \(index + 1) has no match patterns."
        case .contentScriptLimitExceeded(let details):
            return "The extension exceeds a content script safety limit: \(details)"
        case .invalidMatchPattern(let pattern, let reason):
            return "Invalid match pattern '\(pattern)': \(reason)"
        case .unsafeResourcePath(let path):
            return "The extension contains an unsafe resource path: \(path)"
        case .unsupportedPermission(let permission):
            return "The extension requests an unsupported permission: \(permission)"
        case .multipleManifests:
            return "The extension package contains more than one manifest.json."
        case .manifestNotFound:
            return "The extension package does not contain manifest.json."
        }
    }
}

public enum ExtensionInstallError: LocalizedError, Equatable, Sendable {
    case archiveTooLarge(limit: UInt64)
    case archiveUnreadable
    case tooManyEntries(limit: Int)
    case entryTooLarge(path: String, limit: UInt64)
    case expandedArchiveTooLarge(limit: UInt64)
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

public enum ExtensionRuntimeError: LocalizedError, Equatable, Sendable {
    case extensionNotFound(String)
    case extensionDisabled(String)
    case permissionDenied(String)
    case invalidArguments(String)
    case unsupportedAPI(String)
    case unavailable(String)
    case resourceNotFound(String)
    case invalidResourceEncoding(String)
    case contentScriptSourceLimitExceeded(limit: Int)
    case javascriptEvaluationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .extensionNotFound(let identifier):
            return "Extension \(identifier) is not installed."
        case .extensionDisabled(let identifier):
            return "Extension \(identifier) is disabled."
        case .permissionDenied(let permission):
            return "Permission denied: \(permission)"
        case .invalidArguments(let details):
            return "Invalid extension API arguments: \(details)"
        case .unsupportedAPI(let name):
            return "The extension API '\(name)' is not supported."
        case .unavailable(let details):
            return "The requested browser capability is unavailable: \(details)"
        case .resourceNotFound(let path):
            return "Extension resource not found: \(path)"
        case .invalidResourceEncoding(let path):
            return "Extension resource is not valid UTF-8: \(path)"
        case .contentScriptSourceLimitExceeded(let limit):
            return "Prepared content scripts exceed the \(limit) byte limit."
        case .javascriptEvaluationFailed(let details):
            return "JavaScript evaluation failed: \(details)"
        }
    }
}
