import XCTest
@testable import ExtensionBrowser

final class ManifestParserTests: XCTestCase {
    func testParsesManifestV3AndDefaultsOptionalCollections() throws {
        let data = Data(#"{"manifest_version":3,"name":"Hello","version":"1.0.0"}"#.utf8)
        let manifest = try ManifestParser().parse(data: data)

        XCTAssertEqual(manifest.manifestVersion, 3)
        XCTAssertEqual(manifest.name, "Hello")
        XCTAssertEqual(manifest.permissions, [])
        XCTAssertEqual(manifest.hostPermissions, [])
        XCTAssertEqual(manifest.contentScripts, [])
    }

    func testParsesSupportedContentScriptAndAction() throws {
        let data = Data(#"""
        {
          "manifest_version": 3,
          "name": "Example",
          "version": "2.4",
          "permissions": ["storage", "scripting"],
          "host_permissions": ["https://*.example.com/*"],
          "content_scripts": [{
            "matches": ["https://*.example.com/*"],
            "exclude_matches": ["https://private.example.com/*"],
            "js": ["content.js"],
            "css": ["content.css"],
            "run_at": "document_start"
          }],
          "action": {"default_popup": "popup.html", "default_icon": {"32": "icon.png"}}
        }
        """#.utf8)

        let manifest = try ManifestParser().parse(data: data)
        XCTAssertEqual(manifest.contentScripts.first?.runAt, .documentStart)
        XCTAssertEqual(manifest.action?.defaultPopup, "popup.html")
    }

    func testRejectsManifestV2() {
        let data = Data(#"{"manifest_version":2,"name":"Old","version":"1"}"#.utf8)
        XCTAssertThrowsError(try ManifestParser().parse(data: data)) { error in
            XCTAssertEqual(error as? ExtensionManifestError, .unsupportedManifestVersion(2))
        }
    }

    func testRejectsUnknownPermissionAndUnsafeResourcePath() {
        let unknown = Data(#"{"manifest_version":3,"name":"Bad","version":"1","permissions":["nativeMessaging"]}"#.utf8)
        XCTAssertThrowsError(try ManifestParser().parse(data: unknown))

        let unsafe = Data(#"{"manifest_version":3,"name":"Bad","version":"1","content_scripts":[{"matches":["<all_urls>"],"js":["../escape.js"]}]}"#.utf8)
        XCTAssertThrowsError(try ManifestParser().parse(data: unsafe))
    }

    func testRejectsOversizedActionTitle() {
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Action",
            version: "1",
            action: .init(defaultTitle: String(
                repeating: "a",
                count: ManifestValidator.maximumActionTitleBytes + 1
            ))
        )
        XCTAssertThrowsError(try ManifestValidator.validate(manifest))
    }

    func testRejectsBidiFormattingInNativeExtensionMetadata() {
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Trusted\u{202E}txt.exe",
            version: "1"
        )
        XCTAssertThrowsError(try ManifestValidator.validate(manifest))
    }

    func testRejectsExcessiveJSONNestingBeforeDecode() {
        let nested = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try ManifestParser().parse(data: Data(nested.utf8))) { error in
            guard let manifestError = error as? ExtensionManifestError,
                  case .manifestLimitExceeded = manifestError else {
                return XCTFail("Expected the manifest depth limit, got \(error)")
            }
        }
    }

    func testRejectsOversizedManifestAndHostPermissionCollections() {
        let oversized = Data(repeating: 0x20, count: ManifestParser.maximumManifestBytes + 1)
        XCTAssertThrowsError(try ManifestParser().parse(data: oversized)) { error in
            guard let manifestError = error as? ExtensionManifestError,
                  case .manifestLimitExceeded = manifestError else {
                return XCTFail("Expected a manifest size limit error, got \(error)")
            }
        }

        let hosts = Array(
            repeating: "https://example.com/*",
            count: ManifestValidator.maximumHostPermissionCount + 1
        )
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Too many hosts",
            version: "1",
            hostPermissions: hosts
        )
        XCTAssertThrowsError(try ManifestValidator.validate(manifest)) { error in
            guard let manifestError = error as? ExtensionManifestError,
                  case .manifestLimitExceeded = manifestError else {
                return XCTFail("Expected a host permission limit error, got \(error)")
            }
        }
    }

    func testRejectsTooManyContentScriptRules() {
        let script = WebExtensionManifest.ContentScript(
            matches: ["<all_urls>"],
            javascript: ["content.js"]
        )
        let manifest = makeManifest(contentScripts: Array(
            repeating: script,
            count: ManifestValidator.maximumContentScriptCount + 1
        ))

        assertContentScriptLimit { try ManifestValidator.validate(manifest) }
    }

    func testRejectsTooManyResourceReferencesInOneContentScript() {
        let script = WebExtensionManifest.ContentScript(
            matches: ["<all_urls>"],
            javascript: Array(
                repeating: "content.js",
                count: ManifestValidator.maximumResourceReferencesPerContentScript + 1
            )
        )

        assertContentScriptLimit {
            try ManifestValidator.validate(makeManifest(contentScripts: [script]))
        }
    }

    func testRejectsTooManyTotalContentScriptResourceReferences() {
        let fullScript = WebExtensionManifest.ContentScript(
            matches: ["<all_urls>"],
            javascript: Array(
                repeating: "content.js",
                count: ManifestValidator.maximumResourceReferencesPerContentScript
            )
        )
        let fullRuleCount = ManifestValidator.maximumTotalContentScriptResourceReferences
            / ManifestValidator.maximumResourceReferencesPerContentScript
        var scripts = Array(repeating: fullScript, count: fullRuleCount)
        scripts.append(WebExtensionManifest.ContentScript(
            matches: ["<all_urls>"],
            javascript: ["content.js"]
        ))

        assertContentScriptLimit {
            try ManifestValidator.validate(makeManifest(contentScripts: scripts))
        }
    }

    private func makeManifest(
        contentScripts: [WebExtensionManifest.ContentScript]
    ) -> WebExtensionManifest {
        WebExtensionManifest(
            manifestVersion: 3,
            name: "Limits",
            version: "1",
            contentScripts: contentScripts
        )
    }

    private func assertContentScriptLimit(
        _ expression: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let manifestError = error as? ExtensionManifestError,
                  case .contentScriptLimitExceeded = manifestError else {
                XCTFail("Expected a content script limit error, got \(error)", file: file, line: line)
                return
            }
        }
    }
}
