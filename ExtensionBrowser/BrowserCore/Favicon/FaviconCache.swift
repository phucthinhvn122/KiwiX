import Foundation

struct FaviconCacheConfiguration: Sendable {
    var memoryByteLimit: Int = 4 * 1_024 * 1_024
    var diskByteLimit: Int = 24 * 1_024 * 1_024
    var maximumDiskEntryCount: Int = 512
    var maximumEntryByteCount: Int = FaviconImageValidator.maximumEncodedByteCount

    static let `default` = FaviconCacheConfiguration()
}

actor FaviconCache {
    private struct MemoryEntry {
        let data: Data
        var lastAccess: UInt64
    }

    private struct DiskEntry {
        let url: URL
        let byteCount: Int
        let modificationDate: Date
    }

    private let directory: URL
    private let configuration: FaviconCacheConfiguration
    private let fileManager: FileManager
    private var memory: [String: MemoryEntry] = [:]
    private var memoryByteCount = 0
    private var accessCounter: UInt64 = 0

    init(
        directory: URL? = nil,
        configuration: FaviconCacheConfiguration = .default,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.configuration = configuration
        self.fileManager = fileManager
    }

    func data(forKey key: String) -> Data? {
        guard FaviconCacheKey.isValid(key) else { return nil }
        accessCounter &+= 1
        if var entry = memory[key] {
            entry.lastAccess = accessCounter
            memory[key] = entry
            return entry.data
        }

        let url = fileURL(forKey: key)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= configuration.maximumEntryByteCount,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count == byteCount else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        insertIntoMemory(data, forKey: key)
        return data
    }

    func insert(_ data: Data, forKey key: String) {
        guard FaviconCacheKey.isValid(key),
              !data.isEmpty,
              data.count <= configuration.maximumEntryByteCount else {
            return
        }
        insertIntoMemory(data, forKey: key)

        guard configuration.diskByteLimit > 0,
              configuration.maximumDiskEntryCount > 0 else {
            return
        }
        do {
            try ensureDirectoryExists()
            let url = fileURL(forKey: key)
            try data.write(to: url, options: [.atomic])
            try? fileManager.setAttributes(
                [
                    .modificationDate: Date(),
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: url.path
            )
            trimDiskIfNeeded()
        } catch {
            // Cache failures must never affect navigation.
        }
    }

    func removeData(forKey key: String) {
        guard FaviconCacheKey.isValid(key) else { return }
        if let removed = memory.removeValue(forKey: key) {
            memoryByteCount -= removed.data.count
        }
        try? fileManager.removeItem(at: fileURL(forKey: key))
    }

    func removeAll() {
        memory.removeAll(keepingCapacity: false)
        memoryByteCount = 0
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension == "favicon" {
            try? fileManager.removeItem(at: file)
        }
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory
        return caches
            .appendingPathComponent("ExtensionBrowser", isDirectory: true)
            .appendingPathComponent("FaviconCache", isDirectory: true)
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).favicon", isDirectory: false)
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    private func insertIntoMemory(_ data: Data, forKey key: String) {
        guard configuration.memoryByteLimit > 0,
              data.count <= configuration.memoryByteLimit else {
            return
        }
        if let previous = memory.removeValue(forKey: key) {
            memoryByteCount -= previous.data.count
        }
        accessCounter &+= 1
        memory[key] = MemoryEntry(data: data, lastAccess: accessCounter)
        memoryByteCount += data.count

        while memoryByteCount > configuration.memoryByteLimit,
              let oldest = memory.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            memory.removeValue(forKey: oldest.key)
            memoryByteCount -= oldest.value.data.count
        }
    }

    private func trimDiskIfNeeded() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var entries = urls.compactMap { url -> DiskEntry? in
            guard url.pathExtension == "favicon",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            return DiskEntry(
                url: url,
                byteCount: values.fileSize ?? 0,
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
        entries.sort { $0.modificationDate < $1.modificationDate }
        var totalBytes = entries.reduce(0) { $0 + $1.byteCount }
        var totalEntries = entries.count

        for entry in entries where totalBytes > configuration.diskByteLimit ||
            totalEntries > configuration.maximumDiskEntryCount {
            try? fileManager.removeItem(at: entry.url)
            totalBytes -= entry.byteCount
            totalEntries -= 1
        }
    }
}
