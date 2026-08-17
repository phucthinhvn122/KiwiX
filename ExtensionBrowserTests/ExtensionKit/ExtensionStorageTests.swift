import XCTest
@testable import ExtensionBrowser

final class ExtensionStorageTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
    }

    func testStorageIsNamespacedByExtensionIdentifier() async throws {
        let root = makeTemporaryDirectory()
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let firstID = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "c", count: 32)))
        let secondID = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "d", count: 32)))
        try await installFixture(identifier: firstID, digest: String(repeating: "1", count: 64), repository: repository)
        try await installFixture(identifier: secondID, digest: String(repeating: "2", count: 64), repository: repository)

        let storage = ExtensionLocalStorage(repository: repository, maximumBytesPerExtension: 1_024)
        try await storage.set(extensionID: firstID, values: ["key": .string("first")])
        try await storage.set(extensionID: secondID, values: ["key": .string("second")])

        let firstValues = try await storage.get(extensionID: firstID)
        let secondValues = try await storage.get(extensionID: secondID)
        XCTAssertEqual(firstValues, ["key": .string("first")])
        XCTAssertEqual(secondValues, ["key": .string("second")])
        try await storage.remove(extensionID: firstID, keys: ["key"])
        let firstAfterRemoval = try await storage.get(extensionID: firstID)
        let secondAfterRemoval = try await storage.get(extensionID: secondID)
        XCTAssertEqual(firstAfterRemoval, [:])
        XCTAssertEqual(secondAfterRemoval, ["key": .string("second")])
    }

    func testIdentityIncludesHiddenFiles() throws {
        let first = makeTemporaryDirectory()
        let second = makeTemporaryDirectory()
        try Data("same".utf8).write(to: first.appendingPathComponent("manifest.json"))
        try Data("same".utf8).write(to: second.appendingPathComponent("manifest.json"))
        try Data("one".utf8).write(to: first.appendingPathComponent(".hidden"))
        try Data("two".utf8).write(to: second.appendingPathComponent(".hidden"))

        XCTAssertNotEqual(
            try ExtensionIdentityGenerator.identity(forDirectory: first).digest,
            try ExtensionIdentityGenerator.identity(forDirectory: second).digest
        )
    }

    private func installFixture(
        identifier: ExtensionIdentifier,
        digest: String,
        repository: ExtensionRepository
    ) async throws {
        let container = makeTemporaryDirectory()
        let staged = container.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Fixture \(identifier.rawValue.prefix(1))",
            version: "1",
            permissions: ["storage"]
        )
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent("manifest.json"))
        let preview = ExtensionPackagePreview(
            id: identifier,
            manifest: manifest,
            packageDigest: digest,
            stagedDirectoryURL: staged,
            stagingContainerURL: container
        )
        _ = try await repository.install(preview)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
