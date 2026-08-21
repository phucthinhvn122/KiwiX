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

    /// A page that reloads itself must not be able to evict the rest of the history.
    func testRepeatedVisitsToTheSameAddressCollapseOntoOneRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("History.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: fileURL, maximumEntryCount: 3)

        try await store.recordVisit(
            url: try XCTUnwrap(URL(string: "https://keep.example")),
            title: "Keep",
            at: Date(timeIntervalSince1970: 1)
        )
        for second in 2...10 {
            try await store.recordVisit(
                url: try XCTUnwrap(URL(string: "https://reloads.example")),
                title: "Reload \(second)",
                at: Date(timeIntervalSince1970: TimeInterval(second))
            )
        }

        let entries = try await store.entries()
        XCTAssertEqual(entries.map(\.title), ["Reload 10", "Keep"])
        XCTAssertEqual(entries[0].visitedAt, Date(timeIntervalSince1970: 10), "The row moves to the latest visit")
    }

    func testCollapsingAVisitKeepsTheRowIdentifierStable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("History.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: fileURL)
        let url = try XCTUnwrap(URL(string: "https://reloads.example"))

        try await store.recordVisit(url: url, title: "First", at: Date(timeIntervalSince1970: 1))
        let firstID = try await store.entries()[0].id
        try await store.recordVisit(url: url, title: "Second", at: Date(timeIntervalSince1970: 2))

        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, firstID, "A delete already in flight must still name the same row")
        XCTAssertEqual(entries[0].title, "Second")
    }

    /// Only the newest row collapses. Coming back to a page after visiting another one is a
    /// separate visit, and Back/Forward through three sites must not fold into one row.
    func testAnEarlierVisitToTheSameAddressIsNotCollapsed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("History.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: fileURL)

        try await store.recordVisit(
            url: try XCTUnwrap(URL(string: "https://one.example")),
            title: "One",
            at: Date(timeIntervalSince1970: 1)
        )
        try await store.recordVisit(
            url: try XCTUnwrap(URL(string: "https://two.example")),
            title: "Two",
            at: Date(timeIntervalSince1970: 2)
        )
        try await store.recordVisit(
            url: try XCTUnwrap(URL(string: "https://one.example")),
            title: "One again",
            at: Date(timeIntervalSince1970: 3)
        )

        let entries = try await store.entries()
        XCTAssertEqual(entries.map(\.title), ["One again", "Two", "One"])
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
