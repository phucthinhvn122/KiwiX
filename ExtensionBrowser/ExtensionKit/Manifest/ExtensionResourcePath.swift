import Foundation

public enum ExtensionResourcePath {
    /// Validates an archive or manifest path and returns a stable forward-slash form.
    public static func normalize(_ path: String, allowsTrailingSlash: Bool = false) throws -> String {
        guard !path.isEmpty,
              path.utf8.count <= 1_024,
              !path.contains("\0"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.contains("\\"),
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !looksLikeWindowsAbsolutePath(path)
        else {
            throw ExtensionManifestError.unsafeResourcePath(path)
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if allowsTrailingSlash, components.last == "" {
            components.removeLast()
        }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ExtensionManifestError.unsafeResourcePath(path)
        }

        let normalized = components.joined(separator: "/").precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { throw ExtensionManifestError.unsafeResourcePath(path) }
        return normalized
    }

    public static func containedURL(for path: String, under rootURL: URL) throws -> URL {
        let normalized = try normalize(path)
        let root = rootURL.standardizedFileURL
        let candidate = root.appendingPathComponent(normalized, isDirectory: false).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw ExtensionManifestError.unsafeResourcePath(path)
        }
        return candidate
    }

    private static func looksLikeWindowsAbsolutePath(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars.prefix(2))
        guard scalars.count == 2 else { return false }
        let first = scalars[0].value
        let isLetter = (65...90).contains(first) || (97...122).contains(first)
        return isLetter && scalars[1].value == 58
    }
}
