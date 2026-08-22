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

    /// A tab the user had open must survive a relaunch even when its address cannot be persisted.
    /// Dropping the whole record made the tab vanish silently, and a `blob:` or `data:` URL — which
    /// is all it takes to get here — is an ordinary thing for a page to leave a tab sitting on.
    func testATabWithAnUnpersistableURLComesBackEmptyRatherThanVanishing() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionBrowserTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("Tabs.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let keeper = TabRecord(
            id: UUID(),
            title: "Keeper",
            url: URL(string: "https://example.com"),
            faviconURL: nil,
            snapshotFileName: nil,
            lastAccessDate: Date(timeIntervalSince1970: 1_700_000_000),
            isPrivate: false,
            state: .active
        )
        let blobbed = TabRecord(
            id: UUID(),
            title: "Generated document",
            url: try XCTUnwrap(URL(string: "blob:https://example.com/8f0e-4b21")),
            faviconURL: URL(string: "https://example.com/favicon.ico"),
            snapshotFileName: nil,
            lastAccessDate: Date(timeIntervalSince1970: 1_700_000_001),
            isPrivate: false,
            state: .warm
        )
        let store = TabStore(fileURL: fileURL)

        try await store.save(TabSession(selectedTabID: blobbed.id, tabs: [keeper, blobbed]))
        // Hoisted: XCTUnwrap takes an autoclosure, which cannot carry an await.
        let loaded = try await store.load()
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(restored.tabs.count, 2, "Both tabs survive; only the address is dropped")
        let recovered = try XCTUnwrap(restored.tabs.first { $0.id == blobbed.id })
        XCTAssertNil(recovered.url)
        XCTAssertNil(recovered.faviconURL, "An icon for an address that is gone is not an icon")
        XCTAssertEqual(
            restored.selectedTabID,
            blobbed.id,
            "The tab still exists, so it is still a valid selection"
        )
    }

    func testDeepSessionJSONIsQuarantinedBeforeDecode() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionBrowserTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("Tabs.json")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let hostile = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
        try Data(hostile.utf8).write(to: fileURL)
        let store = TabStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected deeply nested session JSON to fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }
}
