import XCTest
@testable import ExtensionBrowser

final class DownloadStoreReconciliationTests: XCTestCase {
    func testStartupReconciliationDeletesTrackedPartialFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let metadata = root.appendingPathComponent("Downloads.json")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let partial = downloads.appendingPathComponent("partial.bin")
        try Data(repeating: 7, count: 128).write(to: partial)
        let store = DownloadStore(fileURL: metadata, downloadsDirectoryURL: downloads)
        let item = DownloadItem(
            sourceURL: URL(string: "https://example.com/partial.bin"),
            fileName: "partial.bin",
            localFileURL: partial,
            bytesReceived: 128,
            status: .downloading,
            isPrivate: false
        )
        try await store.upsert(item, isPrivate: false)

        let reconciled = try await store.reconciledItems()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(reconciled.first?.status, .failed)
        XCTAssertNil(reconciled.first?.localFileURL)
    }

    func testStartupReconciliationSurfacesSafeUntrackedFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let recovered = downloads.appendingPathComponent("recovered.pdf")
        try Data(repeating: 1, count: 64).write(to: recovered)
        let store = DownloadStore(
            fileURL: root.appendingPathComponent("Downloads.json"),
            downloadsDirectoryURL: downloads
        )

        let items = try await store.reconciledItems()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.fileName, "recovered.pdf")
        XCTAssertEqual(items.first?.status, .completed)
        XCTAssertEqual(items.first?.bytesReceived, 64)
    }

    func testStartupReconciliationDeletesUntrackedHiddenPartial() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let partial = downloads.appendingPathComponent(".kiwix-\(UUID().uuidString.lowercased()).partial")
        try Data(repeating: 2, count: 64).write(to: partial)
        let store = DownloadStore(
            fileURL: root.appendingPathComponent("Downloads.json"),
            downloadsDirectoryURL: downloads
        )

        let items = try await store.reconciledItems()

        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testReconciliationDoesNotDeleteNewlyActivePartial() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let identifier = UUID()
        let partial = downloads.appendingPathComponent(
            ".kiwix-\(identifier.uuidString.lowercased()).partial"
        )
        try Data(repeating: 3, count: 64).write(to: partial)
        let registry = ActiveDownloadRegistry()
        registry.insert(identifier)
        let store = DownloadStore(
            fileURL: root.appendingPathComponent("Downloads.json"),
            downloadsDirectoryURL: downloads
        )

        _ = try await store.reconciledItems(activityRegistry: registry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        registry.remove(identifier)
        _ = try await store.reconciledItems(activityRegistry: registry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testCorruptMetadataIsQuarantinedBeforeRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let metadata = root.appendingPathComponent("Downloads.json")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: metadata)
        let store = DownloadStore(fileURL: metadata, downloadsDirectoryURL: downloads)

        let items = try await store.reconciledItems()

        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Downloads-v1.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadReconciliationTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
