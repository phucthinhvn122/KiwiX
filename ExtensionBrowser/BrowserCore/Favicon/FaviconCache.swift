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
    private let maximumDirectoryEntriesToInspect = 4_096
    private var memory: [String: MemoryEntry] = [:]
    private var memoryByteCount = 0
    private var accessCounter: UInt64 = 0
    /// What the cache directory held the last time it was measured, or `nil` when that is no longer
    /// known. Only ever used to decide whether a measurement is needed — see `trimDiskIfNeeded`.
    private var measuredDiskBytes: Int?
    private var measuredDiskEntries: Int?

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
        guard let data = try? BoundedFileReader.read(
            from: url,
            maximumByteCount: configuration.maximumEntryByteCount,
            fileManager: fileManager
        ), !data.isEmpty else {
            // Only a file that was there and turned out to be unreadable changes what is on disk.
            // Forgetting the running total on a plain miss undid the whole point of keeping one:
            // a miss is what precedes every `insert`, so the total was nil every single time
            // `trimDiskIfNeeded` consulted it, and the full directory scan ran anyway — once per
            // newly visited site, exactly as before it was written.
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            try? fileManager.removeItem(at: url)
            forgetMeasuredDiskUsage()
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
            // One `stat` so the running total below can tell a new entry from a replaced one. The
            // alternative it avoids is a full directory scan, which is what this used to cost.
            let replacedExistingFile = fileManager.fileExists(atPath: url.path)
            try data.write(to: url, options: [.atomic])
            try AppDataProtectionPolicy.apply(to: url, category: .browserState, fileManager: fileManager)
            try? fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
            if replacedExistingFile {
                // The size of what it replaced is not known here, and a total that has drifted is
                // worse than no total: measure again rather than guess.
                forgetMeasuredDiskUsage()
            } else if let bytes = measuredDiskBytes, let entries = measuredDiskEntries {
                measuredDiskBytes = bytes + data.count
                measuredDiskEntries = entries + 1
            }
            trimDiskIfNeeded()
        } catch {
            // Cache failures must never affect navigation.
        }
    }

    private func forgetMeasuredDiskUsage() {
        measuredDiskBytes = nil
        measuredDiskEntries = nil
    }

    func removeData(forKey key: String) {
        guard FaviconCacheKey.isValid(key) else { return }
        if let removed = memory.removeValue(forKey: key) {
            memoryByteCount -= removed.data.count
        }
        try? fileManager.removeItem(at: fileURL(forKey: key))
        forgetMeasuredDiskUsage()
    }

    func removeAll() {
        memory.removeAll(keepingCapacity: false)
        memoryByteCount = 0
        forgetMeasuredDiskUsage()
        guard let listing = try? BoundedDirectoryReader.directChildren(
            of: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            maximumEntryCount: maximumDirectoryEntriesToInspect,
            fileManager: fileManager
        ) else { return }
        for file in listing.entries where file.pathExtension == "favicon" {
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

    /// Enforces the disk limits, measuring the directory only when it might be over one.
    ///
    /// This runs on every insert, and it used to enumerate up to 4,096 entries and fetch three
    /// resource values from each of them every time — to discover, almost always, that a cache
    /// holding a few hundred kilobytes of icons is nowhere near a 24 MiB ceiling. The running total
    /// answers that question without touching the filesystem; when it says the ceiling is in reach,
    /// or when it is unknown, the real measurement happens and replaces it.
    ///
    /// Drift is possible — iOS may purge the Caches directory underneath us — and is harmless in
    /// both directions: too high buys one unnecessary scan, too low delays a trim. Every scan
    /// resets the total to what is actually there.
    private func trimDiskIfNeeded() {
        if let bytes = measuredDiskBytes, let entries = measuredDiskEntries,
           bytes <= configuration.diskByteLimit,
           entries <= configuration.maximumDiskEntryCount {
            return
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let listing = try? BoundedDirectoryReader.directChildren(
            of: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            maximumEntryCount: maximumDirectoryEntriesToInspect,
            fileManager: fileManager
        ) else {
            forgetMeasuredDiskUsage()
            return
        }
        var entries = listing.entries.compactMap { url -> DiskEntry? in
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

        // A truncated listing measured part of the directory, so it is not a total.
        if listing.wasTruncated {
            forgetMeasuredDiskUsage()
        } else {
            measuredDiskBytes = totalBytes
            measuredDiskEntries = totalEntries
        }
    }
}
