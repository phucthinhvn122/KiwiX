import WebKit
import XCTest
@testable import ExtensionBrowser

@MainActor
final class PrivateModeTests: XCTestCase {
    /// Spec §7: extensions are off in private browsing. Under Path A that is one property —
    /// a private tab's configuration must carry no `webExtensionController` at all, because the
    /// configuration is copied when the web view is built and cannot be corrected afterwards.
    func testPrivateConfigurationUsesEphemeralIsolationAndCarriesNoExtensionController() {
        let provider = WebViewConfigurationProvider()
        let host = WebExtensionHost(configuration: .nonPersistent())
        provider.webExtensionHost = host

        let normal = provider.configuration(isPrivate: false)
        let firstPrivate = provider.configuration(isPrivate: true)
        let secondPrivate = provider.configuration(isPrivate: true)

        XCTAssertTrue(normal.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertFalse(firstPrivate.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(firstPrivate.websiteDataStore === secondPrivate.websiteDataStore)
        XCTAssertFalse(normal.processPool === firstPrivate.processPool)
        XCTAssertTrue(firstPrivate.processPool === secondPrivate.processPool)

        XCTAssertTrue(
            normal.webExtensionController === host.controller,
            "A normal tab must be attached to the extension controller, or no extension ever runs."
        )
        XCTAssertNil(
            firstPrivate.webExtensionController,
            "A private tab reached the extension controller."
        )
        XCTAssertNil(secondPrivate.webExtensionController)

        provider.resetPrivateProfile()
        let resetPrivate = provider.configuration(isPrivate: true)
        XCTAssertFalse(resetPrivate.websiteDataStore === firstPrivate.websiteDataStore)
        XCTAssertFalse(resetPrivate.processPool === firstPrivate.processPool)
        XCTAssertNil(resetPrivate.webExtensionController)
    }

    func testPrivateTabsAreRemovedAtPersistenceBoundary() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Tabs.json")
        let normal = record(title: "Normal", isPrivate: false)
        let privateRecord = record(title: "Private", isPrivate: true)
        let store = TabStore(fileURL: fileURL)

        try await store.save(TabSession(selectedTabID: privateRecord.id, tabs: [normal, privateRecord]))
        let loaded = try await store.load()
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(restored.tabs, [normal])
        XCTAssertNil(restored.selectedTabID)
    }

    func testPrivateDownloadMetadataIsNotPersisted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("Downloads.json")
        let store = DownloadStore(
            fileURL: metadataURL,
            downloadsDirectoryURL: directory.appendingPathComponent("Files", isDirectory: true)
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.com/private.bin")),
            fileName: "private.bin",
            isPrivate: true
        )

        try await store.upsert(item, isPrivate: true)

        let items = try await store.items()
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateModeTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(title: String, isPrivate: Bool) -> TabRecord {
        TabRecord(
            id: UUID(),
            title: title,
            url: URL(string: "https://example.com"),
            faviconURL: nil,
            snapshotFileName: nil,
            lastAccessDate: Date(timeIntervalSince1970: 1_700_000_000),
            isPrivate: isPrivate,
            state: .active
        )
    }
}
