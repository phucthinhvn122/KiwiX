import XCTest
@testable import ExtensionBrowser

/// Two controls that the Path B teardown removed and that WebKit did not take over.
///
/// `tabs.create`, `tabs.update` and `tabs.duplicate` all re-enter the app through the delegate and
/// the tab adapter, so the app is the only thing that can bound them. These tests exist because the
/// original coverage (`ExtensionAPIRegistry.isAllowedTabURL`, `ExtensionTabCreationLimiter`) was
/// deleted with the runtime that owned it.
@MainActor
final class WebExtensionTabPolicyTests: XCTestCase {

    // MARK: - URL scheme gate

    func testAllowsOnlyTheSchemesAUserCouldHaveTyped() throws {
        for allowed in [
            "https://example.com/page",
            "http://example.com",
            "https://harness.kiwix.test/page.html",
            "about:blank"
        ] {
            let url = try XCTUnwrap(URL(string: allowed))
            XCTAssertTrue(
                WebExtensionTabPolicy.isAllowedNavigationURL(url),
                "\(allowed) should be navigable by an extension."
            )
        }
    }

    /// `TabManager.navigate` hands whatever it is given straight to `WKWebView.load`, and the app's
    /// own navigation gate permits `file`/`data`/`blob` for user-initiated loads. Nothing downstream
    /// of this check would stop an extension reading the app container.
    func testBlocksLocalAndCredentialBearingURLs() throws {
        for blocked in [
            "file:///etc/passwd",
            "file:///var/mobile/Containers/Data/Application/x/Library/state.json",
            "data:text/html,<script>alert(1)</script>",
            "blob:https://example.com/1234",
            "javascript:alert(1)",
            "https://user:password@example.com/",
            "about:srcdoc",
            // Extension-hosted pages are deliberately blocked here. Apple requires them to be
            // opened through `WKWebExtensionContext.webViewConfiguration` in a swapped web view,
            // which nothing in the app does yet (recorded as an M2 gap). When M4 builds that path
            // it must widen this rule on purpose, not by accident.
            "webkit-extension://abc/options.html"
        ] {
            let url = try XCTUnwrap(URL(string: blocked))
            XCTAssertFalse(
                WebExtensionTabPolicy.isAllowedNavigationURL(url),
                "\(blocked) must not be reachable through an extension."
            )
        }
    }

    func testBlocksOverlongURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/" + String(repeating: "a", count: 9_000)))
        XCTAssertFalse(WebExtensionTabPolicy.isAllowedNavigationURL(url))
    }

    // MARK: - Tab creation rate

    /// The 50-tab cap in `TabManager` is a capacity limit: closing a tab frees the slot, so a
    /// create/close loop is unbounded without this.
    func testRateLimiterAllowsUpToTheLimitThenRefuses() {
        let limiter = WebExtensionTabRateLimiter(limit: 3, window: 60)
        let context = NSObject()
        let start = Date(timeIntervalSince1970: 1_000_000)

        for index in 0..<3 {
            XCTAssertTrue(
                limiter.allow(context: context, now: start.addingTimeInterval(Double(index))),
                "Request \(index) is inside the budget."
            )
        }
        XCTAssertFalse(limiter.allow(context: context, now: start.addingTimeInterval(3)))
        // A refused request must not consume budget, or the extension is locked out for longer than
        // the window says.
        XCTAssertFalse(limiter.allow(context: context, now: start.addingTimeInterval(4)))
    }

    func testRateLimiterRecoversAfterTheWindow() {
        let limiter = WebExtensionTabRateLimiter(limit: 2, window: 60)
        let context = NSObject()
        let start = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(limiter.allow(context: context, now: start))
        XCTAssertTrue(limiter.allow(context: context, now: start.addingTimeInterval(1)))
        XCTAssertFalse(limiter.allow(context: context, now: start.addingTimeInterval(2)))

        // Sliding window, not a fixed bucket: at t+30 both events are still inside the 60s
        // window, so nothing has recovered.
        XCTAssertFalse(limiter.allow(context: context, now: start.addingTimeInterval(30)))

        // At t+60.5 the event at t+0 is 60.5s old and gone, but the one at t+1 is only 59.5s old
        // and still counts, so exactly one slot is back — and using it refills the budget.
        XCTAssertTrue(limiter.allow(context: context, now: start.addingTimeInterval(60.5)))
        XCTAssertFalse(limiter.allow(context: context, now: start.addingTimeInterval(60.6)))
    }

    func testBudgetIsPerExtensionNotGlobal() {
        let limiter = WebExtensionTabRateLimiter(limit: 1, window: 60)
        let first = NSObject()
        let second = NSObject()
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(limiter.allow(context: first, now: now))
        XCTAssertFalse(limiter.allow(context: first, now: now))
        XCTAssertTrue(
            limiter.allow(context: second, now: now),
            "One extension exhausting its budget must not block another."
        )
    }

    func testForgetReleasesTheBudget() {
        let limiter = WebExtensionTabRateLimiter(limit: 1, window: 60)
        let context = NSObject()
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(limiter.allow(context: context, now: now))
        XCTAssertFalse(limiter.allow(context: context, now: now))
        limiter.forget(context: context)
        XCTAssertTrue(limiter.allow(context: context, now: now))
    }
}
