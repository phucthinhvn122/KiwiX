import XCTest
@testable import ExtensionBrowser

final class ExternalNavigationPolicyTests: XCTestCase {
    func testScriptDrivenCustomSchemeIsBlocked() throws {
        let url = try XCTUnwrap(URL(string: "evilapp://open"))
        XCTAssertEqual(
            ExternalNavigationPolicy.decision(
                for: url,
                isUserActivated: false,
                isTopLevel: true,
                isActiveTab: true,
                isApplicationActive: true
            ),
            .block
        )
    }

    func testAllowedUserLinkCanOpenOnlyInActiveTopLevelTab() throws {
        let url = try XCTUnwrap(URL(string: "mailto:user@example.com"))
        XCTAssertEqual(
            ExternalNavigationPolicy.decision(
                for: url,
                isUserActivated: true,
                isTopLevel: true,
                isActiveTab: true,
                isApplicationActive: true
            ),
            .open
        )
        XCTAssertEqual(
            ExternalNavigationPolicy.decision(
                for: url,
                isUserActivated: true,
                isTopLevel: true,
                isActiveTab: false,
                isApplicationActive: true
            ),
            .block
        )
    }

    func testUnknownSchemeRequiresConfirmation() throws {
        let url = try XCTUnwrap(URL(string: "exampleapp://account/open"))
        XCTAssertEqual(
            ExternalNavigationPolicy.decision(
                for: url,
                isUserActivated: true,
                isTopLevel: true,
                isActiveTab: true,
                isApplicationActive: true
            ),
            .confirm(displayName: "exampleapp link for account")
        )
    }

    @MainActor
    func testExternalNavigationAndPopupSpamAreRateLimited() {
        let tabID = UUID()
        let now = Date()
        let external = ExternalNavigationRateLimiter(maximumAttempts: 2, window: 60)
        XCTAssertTrue(external.consume(tabID: tabID, now: now))
        XCTAssertTrue(external.consume(tabID: tabID, now: now))
        XCTAssertFalse(external.consume(tabID: tabID, now: now))

        let popup = PopupCreationRateLimiter(maximumAttempts: 1, window: 60)
        XCTAssertTrue(popup.consume(tabID: tabID, now: now))
        XCTAssertFalse(popup.consume(tabID: tabID, now: now))
    }
}
