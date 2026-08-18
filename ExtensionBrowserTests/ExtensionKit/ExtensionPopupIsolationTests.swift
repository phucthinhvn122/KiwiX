import XCTest
@testable import ExtensionBrowser

final class ExtensionPopupIsolationTests: XCTestCase {
    func testPopupPolicyBlocksRemoteAndSocketSchemes() {
        let rules = ExtensionPopupNetworkIsolation.blockedSchemesRuleList
        for scheme in ["http", "https", "ws", "wss", "ftp"] {
            XCTAssertTrue(rules.contains("^\(scheme)"), scheme)
        }
    }

    func testPopupInstallsNetworkAPIDefenseInDepth() {
        let source = ExtensionPopupNetworkIsolation.javaScript
        for api in ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon"] {
            XCTAssertTrue(source.contains(api), api)
        }
    }
}
