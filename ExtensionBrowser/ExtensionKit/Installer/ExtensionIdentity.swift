import CryptoKit
import Foundation

public struct ExtensionIdentity: Equatable, Sendable {
    public let identifier: ExtensionIdentifier
    public let digest: String
}

public enum ExtensionIdentityGenerator {
    public static func identity(
        forDirectory rootURL: URL,
        fileManager: FileManager = .default,
        limits: ZIPSecurityLimits = .default
    ) throws -> ExtensionIdentity {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw ExtensionInstallError.archiveUnreadable
        }

        let rootPath = rootURL.standardizedFileURL.path
        var files: [(path: String, url: URL, size: UInt64)] = []
        var entryCount = 0
        var declaredTotal: UInt64 = 0
        for case let url as URL in enumerator {
            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else {
                throw ExtensionInstallError.tooManyEntries(limit: limits.maximumEntryCount)
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw ExtensionInstallError.symbolicLinkNotAllowed(url.lastPathComponent)
            }
            guard values.isRegularFile == true else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            guard size <= limits.maximumEntryBytes else {
                throw ExtensionInstallError.entryTooLarge(path: url.lastPathComponent, limit: limits.maximumEntryBytes)
            }
            let (nextTotal, overflow) = declaredTotal.addingReportingOverflow(size)
            guard !overflow, nextTotal <= limits.maximumExpandedBytes else {
                throw ExtensionInstallError.expandedArchiveTooLarge(limit: limits.maximumExpandedBytes)
            }
            declaredTotal = nextTotal
            let path = url.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix) else { throw ExtensionInstallError.invalidEntryPath(path) }
            let relative = String(path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
            files.append((relative, url, size))
        }
        files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }

        var hasher = SHA256()
        var actualTotal: UInt64 = 0
        for file in files {
            let pathData = Data(file.path.utf8)
            var pathLength = UInt64(pathData.count).bigEndian
            var fileLength = file.size.bigEndian
            withUnsafeBytes(of: &pathLength) { hasher.update(data: Data($0)) }
            hasher.update(data: pathData)
            withUnsafeBytes(of: &fileLength) { hasher.update(data: Data($0)) }

            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                var actualFileBytes: UInt64 = 0
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    let chunkBytes = UInt64(chunk.count)
                    let (nextFileBytes, fileOverflow) = actualFileBytes.addingReportingOverflow(chunkBytes)
                    let (nextActualTotal, totalOverflow) = actualTotal.addingReportingOverflow(chunkBytes)
                    guard !fileOverflow, !totalOverflow,
                          nextFileBytes <= limits.maximumEntryBytes,
                          nextActualTotal <= limits.maximumExpandedBytes else {
                        throw ExtensionInstallError.expandedArchiveTooLarge(limit: limits.maximumExpandedBytes)
                    }
                    actualFileBytes = nextFileBytes
                    actualTotal = nextActualTotal
                    hasher.update(data: chunk)
                }
                guard actualFileBytes == file.size else {
                    throw ExtensionRuntimeError.integrityCheckFailed("extension resource changed during verification")
                }
            }
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard let identifier = ExtensionIdentifier(rawValue: String(digest.prefix(32))) else {
            throw ExtensionInstallError.archiveUnreadable
        }
        return ExtensionIdentity(identifier: identifier, digest: digest)
    }
}
