import XCTest
@testable import ExtensionBrowser

final class TabStoreTests: XCTestCase {
    func testTabRecordRoundTrip() throws {
        let record = TabRecord(
            id: UUID(),
            title: "Example",
            url: URL(string: "https://example.com"),
            faviconURL: URL(string: "https://example.com/favicon.ico"),
            snapshotFileName: "snapshot.jpg",
            lastAccessDate: Date(timeIntervalSince1970: 1_700_000_000),
            isPrivate: false,
            state: .warm
        )
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(TabRecord.self, from: data), record)
    }

    func testSessionPersistsToInjectedFile() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionBrowserTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("Tabs.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let record = TabRecord(
            id: UUID(),
            title: "Saved",
            url: URL(string: "https://example.com"),
            faviconURL: nil,
            snapshotFileName: nil,
            lastAccessDate: Date(timeIntervalSince1970: 1_700_000_000),
            isPrivate: false,
            state: .active
        )
        let session = TabSession(selectedTabID: record.id, tabs: [record])
        let store = TabStore(fileURL: fileURL)

        try await store.save(session)
        let restoredSession = try await store.load()
        XCTAssertEqual(restoredSession, session)
    }
}
