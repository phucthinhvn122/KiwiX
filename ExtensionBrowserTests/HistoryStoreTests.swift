import XCTest
@testable import ExtensionBrowser

final class HistoryStoreTests: XCTestCase {
    func testRecordsNewestFirstAndRespectsLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("History.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: fileURL, maximumEntryCount: 2)

        try await store.recordVisit(
            url: URL(string: "https://one.example")!,
            title: "One",
            at: Date(timeIntervalSince1970: 1)
        )
        try await store.recordVisit(
            url: URL(string: "https://two.example")!,
            title: "Two",
            at: Date(timeIntervalSince1970: 2)
        )
        try await store.recordVisit(
            url: URL(string: "https://three.example")!,
            title: "Three",
            at: Date(timeIntervalSince1970: 3)
        )

        let entries = try await store.entries()
        XCTAssertEqual(entries.map(\.title), ["Three", "Two"])
    }

    func testClearRemovesPersistedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("History.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: fileURL)

        try await store.recordVisit(url: URL(string: "https://example.com")!, title: "Example")
        try await store.clear()
        let entries = try await store.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testRemovesOnlySelectedHistoryEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("History.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: fileURL)

        try await store.recordVisit(url: URL(string: "https://one.example")!, title: "One")
        try await store.recordVisit(url: URL(string: "https://two.example")!, title: "Two")
        let entries = try await store.entries()

        try await store.remove(id: entries[0].id)

        let remaining = try await store.entries()
        XCTAssertEqual(remaining.map(\.title), ["One"])
    }

    func testPrivateVisitIsNeverPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("History.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: fileURL)

        try await store.recordVisit(
            url: try XCTUnwrap(URL(string: "https://private.example")),
            title: "Private",
            isPrivate: true
        )

        let entries = try await store.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
