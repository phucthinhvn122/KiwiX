import Foundation
import ZIPFoundation

public struct ZIPSecurityLimits: Equatable, Sendable {
    public var maximumArchiveBytes: UInt64
    public var maximumEntryCount: Int
    public var maximumEntryBytes: UInt64
    public var maximumExpandedBytes: UInt64
    public var maximumCompressionRatio: UInt64

    public init(
        maximumArchiveBytes: UInt64 = 50 * 1_024 * 1_024,
        maximumEntryCount: Int = 2_000,
        maximumEntryBytes: UInt64 = 16 * 1_024 * 1_024,
        maximumExpandedBytes: UInt64 = 100 * 1_024 * 1_024,
        maximumCompressionRatio: UInt64 = 250
    ) {
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumCompressionRatio = maximumCompressionRatio
    }

    public static let `default` = ZIPSecurityLimits()
}

public struct SafeZIPExtractor: Sendable {
    public let limits: ZIPSecurityLimits

    public init(limits: ZIPSecurityLimits = .default) {
        self.limits = limits
    }

    public func extract(archiveURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws {
        guard archiveURL.isFileURL else { throw ExtensionInstallError.archiveUnreadable }
        let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { UInt64($0) } ?? 0
        guard archiveSize <= limits.maximumArchiveBytes else {
            throw ExtensionInstallError.archiveTooLarge(limit: limits.maximumArchiveBytes)
        }

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw ExtensionInstallError.archiveUnreadable
        }
        let entries = try Self.collectEntries(archive, maximumCount: limits.maximumEntryCount)

        var total: UInt64 = 0
        var normalizedPaths = Set<String>()
        var validated: [(entry: Entry, path: String)] = []
        validated.reserveCapacity(entries.count)

        for entry in entries {
            let path = try Self.validateEntryPath(entry.path, isDirectory: entry.type == .directory)
            let collisionKey = path.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedPaths.insert(collisionKey).inserted else {
                throw ExtensionInstallError.duplicateEntryPath(path)
            }
            guard entry.type != .symlink else {
                throw ExtensionInstallError.symbolicLinkNotAllowed(path)
            }
            guard entry.uncompressedSize <= limits.maximumEntryBytes else {
                throw ExtensionInstallError.entryTooLarge(path: path, limit: limits.maximumEntryBytes)
            }
            let (newTotal, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, newTotal <= limits.maximumExpandedBytes else {
                throw ExtensionInstallError.expandedArchiveTooLarge(limit: limits.maximumExpandedBytes)
            }
            total = newTotal
            if entry.uncompressedSize > 1_024 * 1_024,
               entry.compressedSize > 0,
               entry.uncompressedSize / entry.compressedSize > limits.maximumCompressionRatio {
                throw ExtensionInstallError.suspiciousCompressionRatio(path)
            }
            if Self.hasNativeBinaryExtension(path) {
                throw ExtensionInstallError.nativeBinaryNotAllowed(path)
            }
            validated.append((entry, path))
        }

        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)
        for item in validated.sorted(by: { $0.path < $1.path }) {
            let targetURL = try Self.containedDestination(for: item.path, under: destinationURL)
            switch item.entry.type {
            case .directory:
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
            case .file:
                let checksum: CRC32
                do {
                    checksum = try archive.extract(item.entry, to: targetURL, bufferSize: 64 * 1_024, skipCRC32: false)
                } catch Archive.ArchiveError.cancelledOperation {
                    throw ExtensionInstallError.cancelled
                } catch {
                    throw ExtensionInstallError.extractionFailed(path: item.path)
                }
                guard checksum == item.entry.checksum else {
                    throw ExtensionInstallError.checksumMismatch(item.path)
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
                if try Self.hasNativeBinaryMagic(at: targetURL) {
                    throw ExtensionInstallError.nativeBinaryNotAllowed(item.path)
                }
            case .symlink:
                throw ExtensionInstallError.symbolicLinkNotAllowed(item.path)
            @unknown default:
                throw ExtensionInstallError.unsupportedEntry(item.path)
            }
        }
    }

    public func copyDirectory(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws {
        guard sourceURL.isFileURL else { throw ExtensionInstallError.archiveUnreadable }
        let rootValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ExtensionInstallError.archiveUnreadable
        }

        let root = sourceURL.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ExtensionInstallError.archiveUnreadable
        }

        var total: UInt64 = 0
        var normalizedPaths = Set<String>()
        var validated: [(source: URL, path: String, isDirectory: Bool)] = []
        for case let source as URL in enumerator {
            guard validated.count < limits.maximumEntryCount else {
                throw ExtensionInstallError.tooManyEntries(limit: limits.maximumEntryCount)
            }
            let standardizedSource = source.standardizedFileURL
            guard standardizedSource.path.hasPrefix(rootPrefix) else {
                throw ExtensionInstallError.invalidEntryPath(source.lastPathComponent)
            }

            let values = try source.resourceValues(forKeys: resourceKeys)
            let relativePath = String(standardizedSource.path.dropFirst(rootPrefix.count))
            guard values.isSymbolicLink != true else {
                throw ExtensionInstallError.symbolicLinkNotAllowed(relativePath)
            }
            guard values.isDirectory == true || values.isRegularFile == true else {
                throw ExtensionInstallError.unsupportedEntry(relativePath)
            }

            let path = try Self.validateEntryPath(relativePath, isDirectory: values.isDirectory == true)
            let collisionKey = path.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedPaths.insert(collisionKey).inserted else {
                throw ExtensionInstallError.duplicateEntryPath(path)
            }
            guard !Self.hasNativeBinaryExtension(path) else {
                throw ExtensionInstallError.nativeBinaryNotAllowed(path)
            }

            if values.isRegularFile == true {
                let size = UInt64(max(values.fileSize ?? 0, 0))
                guard size <= limits.maximumEntryBytes else {
                    throw ExtensionInstallError.entryTooLarge(path: path, limit: limits.maximumEntryBytes)
                }
                let (newTotal, overflow) = total.addingReportingOverflow(size)
                guard !overflow, newTotal <= limits.maximumExpandedBytes else {
                    throw ExtensionInstallError.expandedArchiveTooLarge(limit: limits.maximumExpandedBytes)
                }
                total = newTotal
                if try Self.hasNativeBinaryMagic(at: source) {
                    throw ExtensionInstallError.nativeBinaryNotAllowed(path)
                }
            }
            validated.append((source, path, values.isDirectory == true))
        }
        if enumerationError != nil { throw ExtensionInstallError.archiveUnreadable }

        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)
        for item in validated.sorted(by: { $0.path < $1.path }) {
            let targetURL = try Self.containedDestination(for: item.path, under: destinationURL)
            if item.isDirectory {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
            } else {
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try fileManager.copyItem(at: item.source, to: targetURL)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            }
        }
    }

    public static func validateEntryPath(_ path: String, isDirectory: Bool = false) throws -> String {
        do {
            return try ExtensionResourcePath.normalize(path, allowsTrailingSlash: isDirectory)
        } catch {
            throw ExtensionInstallError.invalidEntryPath(path)
        }
    }

    /// Retains no more than `maximumCount` elements and stops as soon as the
    /// first excess element is observed. This keeps a hostile ZIP central
    /// directory from being fully materialized before its entry limit applies.
    static func collectEntries<S: Sequence>(
        _ entries: S,
        maximumCount: Int
    ) throws -> [S.Element] {
        guard maximumCount >= 0 else {
            throw ExtensionInstallError.tooManyEntries(limit: maximumCount)
        }
        var collected: [S.Element] = []
        collected.reserveCapacity(min(maximumCount, 4_096))
        for entry in entries {
            guard collected.count < maximumCount else {
                throw ExtensionInstallError.tooManyEntries(limit: maximumCount)
            }
            collected.append(entry)
        }
        return collected
    }

    private static func containedDestination(for path: String, under rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        let destination = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw ExtensionInstallError.invalidEntryPath(path)
        }
        return destination
    }

    private static func hasNativeBinaryExtension(_ path: String) -> Bool {
        let prohibited = Set(["dylib", "so", "framework", "bundle", "a", "o", "exe", "dll", "app", "ipa"])
        return path.split(separator: "/").contains { component in
            prohibited.contains((String(component) as NSString).pathExtension.lowercased())
        }
    }

    private static func hasNativeBinaryMagic(at fileURL: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8) ?? Data()
        guard prefix.count >= 2 else { return false }
        let bytes = [UInt8](prefix)
        let four = bytes.count >= 4 ? Array(bytes.prefix(4)) : []
        let executableMagics: [[UInt8]] = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
            [0x7F, 0x45, 0x4C, 0x46]
        ]
        return executableMagics.contains(four) || (bytes[0] == 0x4D && bytes[1] == 0x5A)
    }
}
