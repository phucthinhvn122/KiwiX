import XCTest
@testable import ExtensionBrowser

final class FaviconCacheTests: XCTestCase {
    func testDiskRoundTripAcrossCacheInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaviconCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FaviconCacheConfiguration(
            memoryByteLimit: 0,
            diskByteLimit: 1_024,
            maximumDiskEntryCount: 4,
            maximumEntryByteCount: 128
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/icon.png"))
        let key = try XCTUnwrap(FaviconCacheKey.value(for: url))
        let expected = Data([1, 2, 3, 4])

        let writer = FaviconCache(directory: directory, configuration: configuration)
        await writer.insert(expected, forKey: key)
        let reader = FaviconCache(directory: directory, configuration: configuration)

        let actual = await reader.data(forKey: key)
        XCTAssertEqual(actual, expected)
    }

    func testMemoryCacheEvictsLeastRecentlyUsedEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaviconCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FaviconCacheConfiguration(
            memoryByteLimit: 6,
            diskByteLimit: 0,
            maximumDiskEntryCount: 0,
            maximumEntryByteCount: 8
        )
        let firstKey = try XCTUnwrap(FaviconCacheKey.value(for: URL(string: "https://a.example/icon")!))
        let secondKey = try XCTUnwrap(FaviconCacheKey.value(for: URL(string: "https://b.example/icon")!))
        let cache = FaviconCache(directory: directory, configuration: configuration)

        await cache.insert(Data([1, 2, 3, 4]), forKey: firstKey)
        await cache.insert(Data([5, 6, 7, 8]), forKey: secondKey)

        let first = await cache.data(forKey: firstKey)
        let second = await cache.data(forKey: secondKey)
        XCTAssertNil(first)
        XCTAssertEqual(second, Data([5, 6, 7, 8]))
    }

    /// `trimDiskIfNeeded` now skips the directory scan while its running total says the cache is
    /// under both limits. These two tests exist to prove the total cannot suppress a trim that is
    /// actually due — the failure mode the shortcut introduces is silence, not an error.
    func testDiskEntryCountLimitIsStillEnforcedWithoutRescanning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaviconCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FaviconCacheConfiguration(
            memoryByteLimit: 0,
            diskByteLimit: 1_024 * 1_024,
            maximumDiskEntryCount: 3,
            maximumEntryByteCount: 128
        )
        let cache = FaviconCache(directory: directory, configuration: configuration)

        for index in 0..<8 {
            let url = try XCTUnwrap(URL(string: "https://site\(index).example/icon.png"))
            let key = try XCTUnwrap(FaviconCacheKey.value(for: url))
            await cache.insert(Data([UInt8(index)]), forKey: key)
            // Distinct modification times: the trim evicts oldest-first and the filesystem
            // timestamp is what orders it.
            try await Task.sleep(nanoseconds: 12_000_000)
        }

        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".favicon") }
        XCTAssertLessThanOrEqual(onDisk.count, configuration.maximumDiskEntryCount)
    }

    func testDiskByteLimitIsStillEnforcedWithoutRescanning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaviconCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FaviconCacheConfiguration(
            memoryByteLimit: 0,
            diskByteLimit: 300,
            maximumDiskEntryCount: 512,
            maximumEntryByteCount: 128
        )
        let cache = FaviconCache(directory: directory, configuration: configuration)

        for index in 0..<8 {
            let url = try XCTUnwrap(URL(string: "https://site\(index).example/icon.png"))
            let key = try XCTUnwrap(FaviconCacheKey.value(for: url))
            await cache.insert(Data(repeating: UInt8(index), count: 100), forKey: key)
            try await Task.sleep(nanoseconds: 12_000_000)
        }

        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "favicon" }
        let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, configuration.diskByteLimit)
        XCTAssertFalse(files.isEmpty, "Trimming to nothing would be a different bug")
    }

    /// A miss is what precedes every insert, so if a miss discards the running disk total the total
    /// is nil every time it is consulted and the scan it exists to avoid runs anyway. Asserted
    /// through behaviour rather than private state: after a miss-then-insert cycle the cache must
    /// still be enforcing its limits, and must still hold what it was given.
    func testACacheMissDoesNotDisturbTheStoredEntries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaviconCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FaviconCacheConfiguration(
            memoryByteLimit: 0,
            diskByteLimit: 1_024 * 1_024,
            maximumDiskEntryCount: 8,
            maximumEntryByteCount: 128
        )
        let cache = FaviconCache(directory: directory, configuration: configuration)
        let kept = try XCTUnwrap(FaviconCacheKey.value(for: URL(string: "https://kept.example/i.png")!))
        await cache.insert(Data([9, 9, 9]), forKey: kept)

        // Miss on a key that was never written: nothing on disk may change.
        let absent = try XCTUnwrap(FaviconCacheKey.value(for: URL(string: "https://absent.example/i.png")!))
        let missed = await cache.data(forKey: absent)
        XCTAssertNil(missed)

        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".favicon") }
        XCTAssertEqual(onDisk.count, 1, "A miss must not remove or add anything")
        let reader = FaviconCache(directory: directory, configuration: configuration)
        XCTAssertEqual(await reader.data(forKey: kept), Data([9, 9, 9]))
    }

    func testInvalidKeyCannotEscapeCacheDirectory() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaviconCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FaviconCache(directory: directory)

        await cache.insert(Data([1]), forKey: "../outside")

        let value = await cache.data(forKey: "../outside")
        XCTAssertNil(value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("outside.favicon").path))
    }
}
