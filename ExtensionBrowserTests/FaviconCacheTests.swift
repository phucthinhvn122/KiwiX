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
