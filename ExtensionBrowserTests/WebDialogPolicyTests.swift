import XCTest
@testable import ExtensionBrowser

final class WebDialogPolicyTests: XCTestCase {
    func testDialogUsesActualOriginInsteadOfDocumentTitle() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com:8443/account"))
        let content = WebDialogPolicy.content(pageURL: pageURL, message: "Sign in")
        XCTAssertEqual(content.title, "https://example.com:8443 says:")
        XCTAssertFalse(content.title.contains("Sign in"))
    }

    func testDialogInputIsByteBoundedWithoutSplittingUnicode() {
        let content = WebDialogPolicy.content(
            pageURL: nil,
            message: String(repeating: "🦊", count: 2_000),
            defaultText: String(repeating: "é", count: 1_000)
        )
        XCTAssertLessThanOrEqual(content.message.utf8.count, WebDialogPolicy.maximumMessageByteCount)
        XCTAssertLessThanOrEqual(content.defaultText?.utf8.count ?? 0, WebDialogPolicy.maximumDefaultTextByteCount)
    }

    func testDialogStripsBidiAndControlFormattingButKeepsNewlines() {
        let content = WebDialogPolicy.content(
            pageURL: URL(string: "https://example.com"),
            message: "first\nsecond\u{202E}\u{0000}",
            defaultText: "safe\u{200B}text"
        )
        XCTAssertEqual(content.message, "first\nsecond")
        XCTAssertEqual(content.defaultText, "safetext")
    }
}
