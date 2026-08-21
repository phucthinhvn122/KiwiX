import WebKit
import XCTest
@testable import ExtensionBrowser

/// The contract `WebKitDecisionOnce` exists to hold: a WebKit handler is answered exactly once, and
/// dropping the object counts as an answer. Both halves matter — answering twice is a WebKit trap,
/// and answering zero times is the trap this type was written for.
final class WebKitDecisionOnceTests: XCTestCase {
    func testAnswersOnceWithTheValueGiven() {
        var answers: [WKNavigationActionPolicy] = []
        do {
            let decide = WebKitDecisionOnce<WKNavigationActionPolicy>(fallback: .cancel) {
                answers.append($0)
            }
            decide(.download)
        }
        XCTAssertEqual(answers, [.download])
    }

    func testARepeatedAnswerIsIgnoredAndTheFallbackDoesNotFollowIt() {
        var answers: [WKNavigationActionPolicy] = []
        do {
            let decide = WebKitDecisionOnce<WKNavigationActionPolicy>(fallback: .cancel) {
                answers.append($0)
            }
            decide(.allow)
            decide(.download)
        }
        // Scoped so `decide` is released before the assertion: the second call and the deallocation
        // both have to be silent, not just the second call.
        XCTAssertEqual(answers, [.allow])
    }

    /// The case that motivates the type. `UIAlertController` releases its action closures when it is
    /// dismissed from outside — `BrowserViewController.presentExtensions(importing:)` does exactly
    /// that — and neither button ever runs.
    func testAnUnansweredHandlerIsAnsweredWithTheFallbackWhenReleased() {
        var answers: [WKNavigationActionPolicy] = []
        do {
            _ = WebKitDecisionOnce<WKNavigationActionPolicy>(fallback: .cancel) {
                answers.append($0)
            }
        }
        XCTAssertEqual(answers, [.cancel], "A dropped decision must deny rather than leave WebKit waiting")
    }

    func testTheFallbackForATextPromptIsNoInputRatherThanEmptyInput() {
        var answers: [String?] = []
        do {
            _ = WebKitDecisionOnce<String?>(fallback: nil) { answers.append($0) }
        }
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(answers[0], "An empty string is a value the page can read; a dismissal is not one")
    }
}
