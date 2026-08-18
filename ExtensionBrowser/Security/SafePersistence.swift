import Foundation

enum SafePersistence {
    static let maximumTitleBytes = 1_024
    static let maximumURLBytes = 8_192
    static let maximumTabSessionBytes = 1 * 1_024 * 1_024
    static let maximumHistoryBytes = 8 * 1_024 * 1_024
    static let maximumSnapshotBytes = 4 * 1_024 * 1_024
    static let maximumTabCount = 50

    static func title(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return SafeInput.displayText(trimmed, maximumByteCount: maximumTitleBytes)
    }

    static func isSafePersistedURL(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= maximumURLBytes,
              url.user == nil,
              url.password == nil,
              let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return url.absoluteString == "about:blank" }
        return scheme == "http" || scheme == "https"
    }

    static func snapshotFileName(_ value: String) -> String? {
        guard value.utf8.count == 40,
              value.lowercased().hasSuffix(".jpg") else { return nil }
        let uuidText = String(value.dropLast(4))
        guard let uuid = UUID(uuidString: uuidText) else { return nil }
        return "\(uuid.uuidString.lowercased()).jpg"
    }

    static func containedSnapshotURL(fileName: String, directory: URL) -> URL? {
        guard let normalized = snapshotFileName(fileName) else { return nil }
        let root = directory.standardizedFileURL
        let candidate = root.appendingPathComponent(normalized, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else { return nil }
        return candidate
    }
}
