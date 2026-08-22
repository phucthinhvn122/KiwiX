import XCTest
@testable import ExtensionBrowser

/// An extension that installs cleanly and then does nothing is worse than one that fails to install,
/// because nothing tells the user which of the two happened.
///
/// R-21: `declarativeNetRequest` rules install, report themselves installed, and stop nothing —
/// measured against a real loopback server on every CI run. The app cannot make them work. It can
/// say so, and these tests pin the part that says so.
final class UnenforcedCapabilityTests: XCTestCase {
    func testTheBlockingPermissionsAreTheOnesMeasuredNotToEnforce() {
        XCTAssertTrue(UnenforcedExtensionCapability.permissions.contains("declarativeNetRequest"))
        XCTAssertTrue(UnenforcedExtensionCapability.permissions.contains("webRequest"))
        XCTAssertTrue(UnenforcedExtensionCapability.permissions.contains("webRequestBlocking"))
    }

    /// Content scripts, storage and tabs all work — 42 probes pass. Flagging them would be a lie in
    /// the other direction, and a warning that fires on everything is a warning nobody reads.
    func testCapabilitiesThatDoWorkAreNotFlagged() {
        for permission in ["storage", "tabs", "scripting", "activeTab", "cookies", "alarms"] {
            XCTAssertFalse(
                UnenforcedExtensionCapability.permissions.contains(permission),
                "\(permission) is measured as working; flagging it would be false"
            )
        }
    }

    func testAnInstalledBlockerReportsItsDeadCapability() {
        let record = InstalledExtensionRecord(
            identifier: String(repeating: "a", count: 32),
            displayName: "Blocker",
            format: "crx3",
            publisherIdentifier: nil,
            isSignatureVerified: false,
            installedAt: Date(timeIntervalSince1970: 0),
            isEnabled: true,
            grantedPermissions: ["declarativeNetRequest", "storage", "tabs"],
            grantedMatchPatterns: []
        )
        XCTAssertEqual(record.inertPermissions, ["declarativeNetRequest"])
    }

    func testAnOrdinaryExtensionReportsNothingDead() {
        let record = InstalledExtensionRecord(
            identifier: String(repeating: "b", count: 32),
            displayName: "Reader",
            format: "zip",
            publisherIdentifier: nil,
            isSignatureVerified: false,
            installedAt: Date(timeIntervalSince1970: 0),
            isEnabled: true,
            grantedPermissions: ["storage", "activeTab"],
            grantedMatchPatterns: ["*://*.example.com/*"]
        )
        XCTAssertTrue(record.inertPermissions.isEmpty)
    }
}
