import XCTest
@testable import ExtensionBrowser

final class ContentScriptInjectorTests: XCTestCase {
    func testResourceCacheLoadsEachNormalizedPathOnlyOnce() async throws {
        let cache = ContentScriptResourceCache()
        var loadCount = 0

        let first = try await cache.source(for: "content.js", maximumBytes: 32) {
            loadCount += 1
            return Data("cached".utf8)
        }
        let second = try await cache.source(for: "content.js", maximumBytes: 32) {
            loadCount += 1
            return Data("different".utf8)
        }

        XCTAssertEqual(first, "cached")
        XCTAssertEqual(second, "cached")
        XCTAssertEqual(loadCount, 1)
    }

    @MainActor
    func testPreparationRejectsRepeatedResourceReferencesAboveCumulativeLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Source Limits",
            version: "1",
            contentScripts: [WebExtensionManifest.ContentScript(
                matches: ["<all_urls>"],
                javascript: ["content.js", "content.js"]
            )]
        )
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent("manifest.json"))
        try Data(String(repeating: "a", count: 1_500).utf8)
            .write(to: staged.appendingPathComponent("content.js"))

        let repository = ExtensionRepository(
            baseDirectoryURL: root.appendingPathComponent("Extensions", isDirectory: true)
        )
        let identifier = try XCTUnwrap(
            ExtensionIdentifier(rawValue: String(repeating: "e", count: 32))
        )
        let installed = try await repository.install(ExtensionPackagePreview(
            id: identifier,
            manifest: manifest,
            packageDigest: String(repeating: "3", count: 64),
            stagedDirectoryURL: staged,
            stagingContainerURL: root
        ))
        let limits = ContentScriptPreparationLimits(
            maximumResourceBytes: 2_000,
            maximumPreparedSourceBytes: 2_500
        )

        do {
            _ = try await ContentScriptSourceBuilder.prepare(
                installedExtension: installed,
                repository: repository,
                limits: limits
            )
            XCTFail("Expected the cumulative prepared-source limit to reject repeated references")
        } catch {
            XCTAssertEqual(
                error as? ExtensionRuntimeError,
                .contentScriptSourceLimitExceeded(limit: 2_500)
            )
        }
    }
}
