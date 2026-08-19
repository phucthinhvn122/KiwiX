import XCTest
@testable import ExtensionBrowser

final class ExtensionRepositoryIntegrityTests: XCTestCase {
    func testOneCorruptExtensionDoesNotHideValidExtensions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionsRoot = root.appendingPathComponent("Extensions")
        let repository = ExtensionRepository(baseDirectoryURL: extensionsRoot)
        let valid = try await installFixture(in: root, repository: repository)

        let corruptID = String(repeating: "f", count: 32)
        let corrupt = extensionsRoot.appendingPathComponent(corruptID, isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("metadata.json"))
        try Data("{}".utf8).write(to: corrupt.appendingPathComponent("manifest.json"))

        let installed = try await repository.installedExtensions()
        XCTAssertEqual(installed.map(\.id), [valid.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
    }

    func testModifiedInstalledResourceFailsIntegrityAndIsQuarantined() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let valid = try await installFixture(in: root, repository: repository)
        try Data("tampered".utf8).write(to: valid.filesURL.appendingPathComponent("content.js"))

        let installed = try await repository.installedExtensions()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.directoryURL.path))
    }

    func testModifiedRuntimeManifestCannotBypassPackagedDigest() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let valid = try await installFixture(in: root, repository: repository)
        let tamperedManifest = WebExtensionManifest(
            manifestVersion: 3,
            name: valid.manifest.name,
            version: valid.manifest.version,
            contentScripts: [
                .init(matches: ["<all_urls>"], javascript: ["content.js"])
            ]
        )
        try JSONEncoder().encode(tamperedManifest).write(
            to: valid.directoryURL.appendingPathComponent("manifest.json")
        )

        let installed = try await repository.installedExtensions()

        XCTAssertTrue(installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.directoryURL.path))
    }

    func testDirectoryIdentifierMismatchIsQuarantined() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionsRoot = root.appendingPathComponent("Extensions")
        let repository = ExtensionRepository(baseDirectoryURL: extensionsRoot)
        let valid = try await installFixture(in: root, repository: repository)
        let differentID = valid.id.rawValue == String(repeating: "f", count: 32)
            ? String(repeating: "e", count: 32)
            : String(repeating: "f", count: 32)
        let renamed = extensionsRoot.appendingPathComponent(differentID, isDirectory: true)
        try FileManager.default.moveItem(at: valid.directoryURL, to: renamed)

        let installed = try await repository.installedExtensions()

        XCTAssertTrue(installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testStoredDigestMismatchIsQuarantined() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let valid = try await installFixture(in: root, repository: repository)
        let tamperedMetadata = ExtensionMetadata(
            id: valid.id,
            manifest: valid.manifest,
            installedAt: valid.metadata.installedAt,
            isEnabled: valid.metadata.isEnabled,
            packageDigest: String(repeating: "0", count: 64)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tamperedMetadata).write(
            to: valid.directoryURL.appendingPathComponent("metadata.json")
        )

        let installed = try await repository.installedExtensions()

        XCTAssertTrue(installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.directoryURL.path))
    }

    func testReinstallQuarantinesCorruptExistingDirectoryInsteadOfRemainingBlocked() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let valid = try await installFixture(in: root, repository: repository)
        try Data("tampered".utf8).write(to: valid.filesURL.appendingPathComponent("content.js"))

        let stagingContainer = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = stagingContainer.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: valid.filesURL.appendingPathComponent("manifest.json"),
            to: staged.appendingPathComponent("manifest.json")
        )
        try Data("console.log('safe')".utf8).write(to: staged.appendingPathComponent("content.js"))
        let identity = try ExtensionIdentityGenerator.identity(forDirectory: staged)
        XCTAssertEqual(identity.identifier, valid.id)

        let reinstalled = try await repository.install(ExtensionPackagePreview(
            id: identity.identifier,
            manifest: valid.manifest,
            packageDigest: identity.digest,
            stagedDirectoryURL: staged,
            stagingContainerURL: stagingContainer
        ))

        XCTAssertEqual(reinstalled.id, valid.id)
        XCTAssertEqual(
            try BoundedFileReader.read(
                from: reinstalled.filesURL.appendingPathComponent("content.js"),
                maximumByteCount: 1_024
            ),
            Data("console.log('safe')".utf8)
        )
    }

    func testInstalledExtensionCountIsBoundedBeforeAnotherPackageIsCommitted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(
            baseDirectoryURL: root.appendingPathComponent("Extensions"),
            maximumInstalledExtensionCount: 2
        )
        _ = try await repository.install(makePreview(index: 1, in: root))
        _ = try await repository.install(makePreview(index: 2, in: root))

        do {
            _ = try await repository.install(makePreview(index: 3, in: root))
            XCTFail("Expected installed extension count limit")
        } catch {
            XCTAssertEqual(error as? ExtensionInstallError, .tooManyInstalledExtensions(limit: 2))
        }
        let installed = try await repository.installedExtensions()
        XCTAssertEqual(installed.count, 2)
    }

    func testRepositoryScanFailsClosedWhenDirectoryInspectionIsTruncated() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionsRoot = root.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionsRoot, withIntermediateDirectories: true)
        for index in 0..<257 {
            try Data().write(to: extensionsRoot.appendingPathComponent("junk-\(index)"))
        }
        let repository = ExtensionRepository(
            baseDirectoryURL: extensionsRoot,
            maximumInstalledExtensionCount: 1
        )

        do {
            _ = try await repository.installedExtensions()
            XCTFail("Expected oversized repository inspection to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ExtensionRuntimeError,
                .unavailable("extension repository contains too many entries")
            )
        }
    }

    func testPermissionGrantsPersistAndCanBeRevoked() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let installed = try await installFixture(
            in: root,
            repository: repository,
            permissions: ["scripting"],
            hostPermissions: ["<all_urls>"]
        )
        XCTAssertFalse(installed.metadata.grantedPermissions.contains("scripting"))
        XCTAssertFalse(installed.metadata.grantedHostPermissions.contains("<all_urls>"))

        _ = try await repository.setCapability(.scripting, granted: true, extensionID: installed.id)
        _ = try await repository.setHostPermission("<all_urls>", granted: true, extensionID: installed.id)
        var reloadedValue = try await repository.extensionWithID(installed.id)
        var reloaded = try XCTUnwrap(reloadedValue)
        XCTAssertTrue(reloaded.metadata.grantedPermissions.contains("scripting"))
        XCTAssertTrue(reloaded.metadata.grantedHostPermissions.contains("<all_urls>"))

        _ = try await repository.setHostPermission("<all_urls>", granted: false, extensionID: installed.id)
        reloadedValue = try await repository.extensionWithID(installed.id)
        reloaded = try XCTUnwrap(reloadedValue)
        XCTAssertFalse(reloaded.metadata.grantedHostPermissions.contains("<all_urls>"))
    }

    func testSelectedWebsiteGrantPersistsAsNarrowPattern() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let installed = try await installFixture(
            in: root,
            repository: repository,
            permissions: ["scripting"],
            hostPermissions: ["<all_urls>"]
        )

        _ = try await repository.replaceHostPermissions(
            withWebsiteHostname: "Example.com.",
            extensionID: installed.id
        )
        let initialReload = try await repository.extensionWithID(installed.id)
        var reloaded = try XCTUnwrap(initialReload)
        XCTAssertEqual(reloaded.metadata.grantedHostPermissions, ["*://example.com/*"])

        _ = try await repository.setWebsitePermission(
            hostname: "example.com",
            granted: false,
            extensionID: installed.id
        )
        let finalReload = try await repository.extensionWithID(installed.id)
        reloaded = try XCTUnwrap(finalReload)
        XCTAssertTrue(reloaded.metadata.grantedHostPermissions.isEmpty)
    }

    private func installFixture(
        in root: URL,
        repository: ExtensionRepository,
        permissions: [String] = [],
        hostPermissions: [String] = []
    ) async throws -> InstalledExtension {
        let stagingContainer = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = stagingContainer.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Integrity Fixture",
            version: "1",
            permissions: permissions,
            hostPermissions: hostPermissions
        )
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent("manifest.json"))
        try Data("console.log('safe')".utf8).write(to: staged.appendingPathComponent("content.js"))
        let identity = try ExtensionIdentityGenerator.identity(forDirectory: staged)
        return try await repository.install(ExtensionPackagePreview(
            id: identity.identifier,
            manifest: manifest,
            packageDigest: identity.digest,
            stagedDirectoryURL: staged,
            stagingContainerURL: stagingContainer
        ))
    }

    private func makePreview(index: Int, in root: URL) throws -> ExtensionPackagePreview {
        let stagingContainer = root.appendingPathComponent("count-\(index)-\(UUID().uuidString)", isDirectory: true)
        let staged = stagingContainer.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Count Fixture \(index)",
            version: "1"
        )
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent("manifest.json"))
        try Data("fixture-\(index)".utf8).write(to: staged.appendingPathComponent("fixture.txt"))
        let identity = try ExtensionIdentityGenerator.identity(forDirectory: staged)
        return ExtensionPackagePreview(
            id: identity.identifier,
            manifest: manifest,
            packageDigest: identity.digest,
            stagedDirectoryURL: staged,
            stagingContainerURL: stagingContainer
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
