import XCTest
@testable import ExtensionBrowser

final class PermissionManagerTests: XCTestCase {
    func testCapabilitiesHostPermissionsAndActiveTab() async throws {
        let manager = ExtensionPermissionManager()
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "b", count: 32)))
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Permissions",
            version: "1",
            permissions: ["storage", "scripting", "activeTab"],
            hostPermissions: ["https://*.example.com/*"]
        )
        try await manager.register(extensionID: identifier, manifest: manifest, isEnabled: true)
        let activeTabID = UUID()

        try await manager.authorize(.storage, extensionID: identifier)
        await XCTAssertThrowsErrorAsync {
            try await manager.authorize(.tabs, extensionID: identifier)
        }
        try await manager.authorizeHost(
            XCTUnwrap(URL(string: "https://docs.example.com/page")),
            tabID: nil,
            extensionID: identifier
        )

        let temporary = try XCTUnwrap(URL(string: "https://temporary.test/page"))
        await XCTAssertThrowsErrorAsync {
            try await manager.authorizeHost(temporary, tabID: activeTabID, extensionID: identifier)
        }
        try await manager.grantActiveTab(temporary, tabID: activeTabID, extensionID: identifier)
        try await manager.authorizeHost(temporary, tabID: activeTabID, extensionID: identifier)

        await XCTAssertThrowsErrorAsync {
            try await manager.authorizeHost(temporary, tabID: UUID(), extensionID: identifier)
        }
        await manager.revokeActiveTabGrant(tabID: activeTabID)
        await XCTAssertThrowsErrorAsync {
            try await manager.authorizeHost(temporary, tabID: activeTabID, extensionID: identifier)
        }
        try await manager.setEnabled(false, extensionID: identifier)
        await XCTAssertThrowsErrorAsync { try await manager.authorize(.storage, extensionID: identifier) }
    }

    func testContentScriptMatchesDoNotGrantProgrammaticHostAccessAndHonorExcludes() async throws {
        let manager = ExtensionPermissionManager()
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "c", count: 32)))
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Declarative only",
            version: "1",
            permissions: ["scripting"],
            contentScripts: [
                .init(
                    matches: ["https://*.example.com/*"],
                    excludeMatches: ["https://private.example.com/*"],
                    javascript: ["content.js"]
                )
            ]
        )
        try await manager.register(extensionID: identifier, manifest: manifest, isEnabled: true)

        let publicPage = try XCTUnwrap(URL(string: "https://www.example.com/page"))
        let excludedPage = try XCTUnwrap(URL(string: "https://private.example.com/page"))
        let mayInjectPublicPage = await manager.canInject(
            into: publicPage,
            tabID: nil,
            extensionID: identifier
        )
        let mayInjectExcludedPage = await manager.canInject(
            into: excludedPage,
            tabID: nil,
            extensionID: identifier
        )
        XCTAssertTrue(mayInjectPublicPage)
        XCTAssertFalse(mayInjectExcludedPage)
        await XCTAssertThrowsErrorAsync {
            try await manager.authorizeHost(publicPage, tabID: nil, extensionID: identifier)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
