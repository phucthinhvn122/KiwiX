import XCTest
@testable import ExtensionBrowser

final class MatchPatternTests: XCTestCase {
    func testWildcardSubdomainMatchesBaseAndChildren() throws {
        let pattern = try WebExtensionMatchPattern("https://*.example.com/*")
        XCTAssertTrue(pattern.matches(try XCTUnwrap(URL(string: "https://example.com/"))))
        XCTAssertTrue(pattern.matches(try XCTUnwrap(URL(string: "https://a.b.example.com/path?q=1"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URL(string: "http://example.com/"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URL(string: "https://notexample.com/"))))
    }

    func testWildcardSchemeIsHTTPAndHTTPSOnly() throws {
        let pattern = try WebExtensionMatchPattern("*://example.com/*")
        XCTAssertTrue(pattern.matches(try XCTUnwrap(URL(string: "http://example.com/a"))))
        XCTAssertTrue(pattern.matches(try XCTUnwrap(URL(string: "https://example.com/a"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URL(string: "ftp://example.com/a"))))
    }

    func testAllURLsIncludesFileAndPathMatchesQuery() throws {
        XCTAssertTrue(try WebExtensionMatchPattern("<all_urls>").matches(
            XCTUnwrap(URL(string: "file:///tmp/example.html"))
        ))
        let query = try WebExtensionMatchPattern("https://example.com/search?q=*")
        XCTAssertTrue(query.matches(try XCTUnwrap(URL(string: "https://example.com/search?q=swift"))))
        XCTAssertFalse(query.matches(try XCTUnwrap(URL(string: "https://example.com/search?page=2"))))
    }

    func testCompiledRuleHonorsExclusions() throws {
        let id = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "a", count: 32)))
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Matcher",
            version: "1",
            contentScripts: [.init(
                matches: ["https://*.example.com/*"],
                excludeMatches: ["https://private.example.com/*"]
            )]
        )
        let rule = try XCTUnwrap(ExtensionRuleCompiler.compile(manifest: manifest, extensionID: id).first)
        XCTAssertTrue(rule.matches(try XCTUnwrap(URL(string: "https://www.example.com/"))))
        XCTAssertFalse(rule.matches(try XCTUnwrap(URL(string: "https://private.example.com/"))))
    }

    func testRejectsInvalidWildcardAndPort() {
        XCTAssertThrowsError(try WebExtensionMatchPattern("https://foo.*.example.com/*"))
        XCTAssertThrowsError(try WebExtensionMatchPattern("https://example.com:443/*"))
    }

    func testNarrowedWebsiteGrantRemainsWithinDeclaredPattern() throws {
        let declared = try WebExtensionMatchPattern("https://*.example.com/account/*")
        let narrowed = try XCTUnwrap(declared.narrowed(toHostname: "docs.example.com"))

        XCTAssertEqual(narrowed.source, "https://docs.example.com/account/*")
        XCTAssertTrue(declared.encompasses(narrowed))
        XCTAssertFalse(narrowed.encompasses(declared))
        XCTAssertNil(declared.narrowed(toHostname: "notexample.com"))
        XCTAssertFalse(declared.encompasses(try WebExtensionMatchPattern("https://docs.example.com/*")))
    }

    func testAllURLsCanBeNarrowedWithoutGrantingFileOrOtherHosts() throws {
        let declared = try WebExtensionMatchPattern("<all_urls>")
        let narrowed = try XCTUnwrap(declared.narrowed(toHostname: "example.com"))
        XCTAssertEqual(narrowed.source, "*://example.com/*")
        XCTAssertTrue(narrowed.matches(try XCTUnwrap(URL(string: "https://example.com/page"))))
        XCTAssertFalse(narrowed.matches(try XCTUnwrap(URL(string: "https://other.test/page"))))
        XCTAssertFalse(narrowed.matches(try XCTUnwrap(URL(string: "file:///tmp/page"))))
    }
}
