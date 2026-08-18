import WebKit
import XCTest
@testable import ExtensionBrowser

@MainActor
final class PrivateModeTests: XCTestCase {
    func testPrivateConfigurationUsesEphemeralIsolationAndSkipsExtensionIntegration() {
        let bridge = BrowserExtensionBridge.shared
        let previousIntegration = bridge.integration
        let integration = ExtensionIntegrationSpy()
        bridge.integration = integration
        defer { bridge.integration = previousIntegration }
        let provider = WebViewConfigurationProvider(extensionBridge: bridge)

        let normal = provider.configuration(tabID: UUID(), isPrivate: false)
        let firstPrivate = provider.configuration(tabID: UUID(), isPrivate: true)
        let secondPrivate = provider.configuration(tabID: UUID(), isPrivate: true)

        XCTAssertTrue(normal.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertFalse(firstPrivate.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(firstPrivate.websiteDataStore === secondPrivate.websiteDataStore)
        XCTAssertFalse(normal.processPool === firstPrivate.processPool)
        XCTAssertTrue(firstPrivate.processPool === secondPrivate.processPool)
        XCTAssertEqual(integration.configuredContexts.count, 1)
        XCTAssertEqual(integration.configuredContexts.first?.isPrivate, false)

        provider.resetPrivateProfile()
        let resetPrivate = provider.configuration(tabID: UUID(), isPrivate: true)
        XCTAssertFalse(resetPrivate.websiteDataStore === firstPrivate.websiteDataStore)
        XCTAssertFalse(resetPrivate.processPool === firstPrivate.processPool)
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

@MainActor
private final class ExtensionIntegrationSpy: BrowserExtensionIntegrating {
    private(set) var configuredContexts: [BrowserExtensionTabContext] = []

    func configure(
        userContentController: WKUserContentController,
        context: BrowserExtensionTabContext
    ) {
        configuredContexts.append(context)
    }
}
