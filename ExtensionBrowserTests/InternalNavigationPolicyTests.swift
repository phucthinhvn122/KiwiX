import XCTest
@testable import ExtensionBrowser

final class InternalNavigationPolicyTests: XCTestCase {
    func testTopLevelDataNavigationIsRefused() {
        XCTAssertTrue(
            InternalNavigationPolicy.blocksTopLevelNavigation(
                scheme: "data",
                isTopLevel: true,
                isDownload: false
            )
        )
    }

    func testSchemeComparisonIsCaseInsensitive() {
        XCTAssertTrue(
            InternalNavigationPolicy.blocksTopLevelNavigation(
                scheme: "DaTa",
                isTopLevel: true,
                isDownload: false
            ),
            "A scheme is case-insensitive, so upper case must not be a way past the rule"
        )
    }

    /// The parent document's origin is what the address bar reports for a subframe, so the reason
    /// the rule exists does not apply there.
    func testSubframeDataNavigationIsAllowed() {
        XCTAssertFalse(
            InternalNavigationPolicy.blocksTopLevelNavigation(
                scheme: "data",
                isTopLevel: false,
                isDownload: false
            )
        )
    }

    /// `<a download href="data:…">` is how a page hands over a file it built client-side. It never
    /// renders as a document, so blocking it would break saving rather than prevent spoofing.
    func testDataDownloadIsAllowed() {
        XCTAssertFalse(
            InternalNavigationPolicy.blocksTopLevelNavigation(
                scheme: "data",
                isTopLevel: true,
                isDownload: true
            )
        )
    }

    func testNoOtherSupportedSchemeIsBlocked() {
        for scheme in ["http", "https", "about", "file", "blob"] {
            XCTAssertFalse(
                InternalNavigationPolicy.blocksTopLevelNavigation(
                    scheme: scheme,
                    isTopLevel: true,
                    isDownload: false
                ),
                "\(scheme) must keep loading; only data: hides its origin from the address bar"
            )
        }
    }

    func testTheSupportedSetIsTheOneTheBrowserRenders() {
        XCTAssertEqual(
            InternalNavigationPolicy.supportedSchemes,
            ["http", "https", "about", "file", "data", "blob"]
        )
        XCTAssertFalse(InternalNavigationPolicy.isInternallySupported(scheme: "mailto"))
        XCTAssertFalse(InternalNavigationPolicy.isInternallySupported(scheme: "javascript"))
        XCTAssertTrue(InternalNavigationPolicy.isInternallySupported(scheme: "HTTPS"))
    }
}
