import CryptoKit
import Foundation

public struct ExtensionIdentity: Equatable, Sendable {
    public let identifier: ExtensionIdentifier
    public let digest: String
}

public enum ExtensionIdentityGenerator {
    public static func identity(forDirectory rootURL: URL, fileManager: FileManager = .default) throws -> ExtensionIdentity {
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
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw ExtensionInstallError.symbolicLinkNotAllowed(url.lastPathComponent)
            }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix) else { throw ExtensionInstallError.invalidEntryPath(path) }
            let relative = String(path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
            files.append((relative, url, UInt64(values.fileSize ?? 0)))
        }
        files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }

        var hasher = SHA256()
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
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    hasher.update(data: chunk)
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
