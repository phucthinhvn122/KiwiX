import XCTest
@testable import ExtensionBrowser

final class PermissionManagerTests: XCTestCase {
    func testDeclaredPermissionsAreNotGrantedAndAllURLsIsFailClosedByDefault() async throws {
        let manager = ExtensionPermissionManager()
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "a", count: 32)))
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Fail Closed",
            version: "1",
            permissions: ["storage", "scripting"],
            hostPermissions: ["<all_urls>"],
            contentScripts: [.init(matches: ["<all_urls>"], javascript: ["content.js"])]
        )
        try await manager.register(extensionID: identifier, manifest: manifest, isEnabled: true)

        await XCTAssertThrowsErrorAsync {
            try await manager.authorize(.storage, extensionID: identifier)
        }
        let mayInject = await manager.canInject(
            into: XCTUnwrap(URL(string: "https://example.com")),
            tabID: nil,
            extensionID: identifier
        )
        let snapshot = await manager.snapshot(extensionID: identifier)
        XCTAssertFalse(mayInject)
        XCTAssertEqual(snapshot?.capabilities, [])
        XCTAssertEqual(snapshot?.hostPatterns, [])
    }

    func testCapabilityRevokeIsImmediate() async throws {
        let manager = ExtensionPermissionManager()
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "f", count: 32)))
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Revoke",
            version: "1",
            permissions: ["storage"]
        )
        try await manager.register(
            extensionID: identifier,
            manifest: manifest,
            isEnabled: true,
            grantedCapabilities: [.storage]
        )
        try await manager.authorize(.storage, extensionID: identifier)
        try await manager.setCapability(.storage, granted: false, extensionID: identifier)
        await XCTAssertThrowsErrorAsync {
            try await manager.authorize(.storage, extensionID: identifier)
        }
    }

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
        try await manager.register(
            extensionID: identifier,
            manifest: manifest,
            isEnabled: true,
            grantDeclaredPermissions: true
        )
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
        try await manager.register(
            extensionID: identifier,
            manifest: manifest,
            isEnabled: true,
            grantedCapabilities: [.scripting],
            grantedHostPermissions: ["https://*.example.com/*"]
        )

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

    func testSelectedWebsiteGrantNarrowsBroadDeclaration() async throws {
        let manager = ExtensionPermissionManager()
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "d", count: 32)))
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Selected website",
            version: "1",
            permissions: ["scripting"],
            hostPermissions: ["<all_urls>"],
            contentScripts: [.init(matches: ["<all_urls>"], javascript: ["content.js"])]
        )
        try await manager.register(
            extensionID: identifier,
            manifest: manifest,
            isEnabled: true,
            grantedCapabilities: [.scripting],
            grantedHostPermissions: ["*://example.com/*"]
        )

        let selected = try XCTUnwrap(URL(string: "https://example.com/page"))
        let other = try XCTUnwrap(URL(string: "https://other.test/page"))
        try await manager.authorizeHost(selected, tabID: nil, extensionID: identifier)
        let mayInjectSelected = await manager.canInject(into: selected, tabID: nil, extensionID: identifier)
        let mayInjectOther = await manager.canInject(into: other, tabID: nil, extensionID: identifier)
        XCTAssertTrue(mayInjectSelected)
        XCTAssertFalse(mayInjectOther)
        await XCTAssertThrowsErrorAsync {
            try await manager.authorizeHost(other, tabID: nil, extensionID: identifier)
        }
    }

    func testNavigationRevokesActiveTabAcrossExtensionsAndDisableCannotRestoreIt() async throws {
        let manager = ExtensionPermissionManager()
        let first = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "1", count: 32)))
        let second = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "2", count: 32)))
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Temporary access",
            version: "1",
            permissions: ["activeTab"]
        )
        for identifier in [first, second] {
            try await manager.register(
                extensionID: identifier,
                manifest: manifest,
                isEnabled: true,
                grantedCapabilities: [.activeTab]
            )
        }
        let tabID = UUID()
        let page = try XCTUnwrap(URL(string: "https://temporary.example/page"))
        try await manager.grantActiveTab(page, tabID: tabID, extensionID: first)
        try await manager.grantActiveTab(page, tabID: tabID, extensionID: second)

        await manager.revokeActiveTabGrant(tabID: tabID)

        for identifier in [first, second] {
            await XCTAssertThrowsErrorAsync {
                try await manager.authorizeHost(page, tabID: tabID, extensionID: identifier)
            }
        }

        try await manager.grantActiveTab(page, tabID: tabID, extensionID: first)
        try await manager.setEnabled(false, extensionID: first)
        try await manager.setEnabled(true, extensionID: first)
        await XCTAssertThrowsErrorAsync {
            try await manager.authorizeHost(page, tabID: tabID, extensionID: first)
        }

        try await manager.grantActiveTab(page, tabID: tabID, extensionID: first)
        try await manager.setCapability(.activeTab, granted: false, extensionID: first)
        await XCTAssertThrowsErrorAsync {
            try await manager.authorizeHost(page, tabID: tabID, extensionID: first)
        }
        let mayInjectAfterRevoke = await manager.canInject(
            into: page,
            tabID: tabID,
            extensionID: first
        )
        XCTAssertFalse(mayInjectAfterRevoke)
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
