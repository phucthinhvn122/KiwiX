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
        let firstID = try await installFixture(seed: String(repeating: "c", count: 32), repository: repository)
        let secondID = try await installFixture(seed: String(repeating: "d", count: 32), repository: repository)

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

    func testOversizedStorageOperationIsRejectedBeforePersistence() async throws {
        let root = makeTemporaryDirectory()
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Quota Fixture",
            version: "1",
            permissions: ["storage"]
        )
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent("manifest.json"))
        let identity = try ExtensionIdentityGenerator.identity(forDirectory: staged)
        _ = try await repository.install(ExtensionPackagePreview(
            id: identity.identifier,
            manifest: manifest,
            packageDigest: identity.digest,
            stagedDirectoryURL: staged,
            stagingContainerURL: root
        ))
        let storage = ExtensionLocalStorage(repository: repository)
        let oversized = String(
            repeating: "x",
            count: ExtensionResourceLimits.standard.maximumStorageOperationBytes + 1
        )

        await assertThrowsAsyncStorage {
            try await storage.set(extensionID: identity.identifier, values: ["large": .string(oversized)])
        }
        let recovered = try await storage.get(extensionID: identity.identifier)
        XCTAssertEqual(recovered, [:])
    }

    func testCorruptPersistedStorageIsQuarantinedAndRecoversEmpty() async throws {
        let root = makeTemporaryDirectory()
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let identifier = try await installFixture(
            seed: String(repeating: "e", count: 32),
            repository: repository
        )
        let installed = try XCTUnwrap(try await repository.extensionWithID(identifier))
        let storageURL = installed.storageURL.appendingPathComponent("local.json")
        try Data(#"{"broken":[[[}"#.utf8).write(to: storageURL)
        let storage = ExtensionLocalStorage(repository: repository, maximumBytesPerExtension: 1_024)

        let recovered = try await storage.get(extensionID: identifier)

        XCTAssertEqual(recovered, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: installed.storageURL.path)
            .filter { $0.hasPrefix("local.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(quarantined.count, 1)
    }

    private func installFixture(
        seed: String,
        repository: ExtensionRepository
    ) async throws -> ExtensionIdentifier {
        let container = makeTemporaryDirectory()
        let staged = container.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Fixture \(seed.prefix(1))",
            version: "1",
            permissions: ["storage"]
        )
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent("manifest.json"))
        // Give otherwise-identical fixtures distinct deterministic identities.
        try Data(seed.utf8).write(to: staged.appendingPathComponent("fixture-id.txt"))
        let identity = try ExtensionIdentityGenerator.identity(forDirectory: staged)
        let preview = ExtensionPackagePreview(
            id: identity.identifier,
            manifest: manifest,
            packageDigest: identity.digest,
            stagedDirectoryURL: staged,
            stagingContainerURL: container
        )
        _ = try await repository.install(preview)
        return identity.identifier
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

private extension XCTestCase {
    func assertThrowsAsyncStorage(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
