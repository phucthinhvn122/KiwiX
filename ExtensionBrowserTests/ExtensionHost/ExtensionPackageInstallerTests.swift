import XCTest
@testable import ExtensionBrowser

/// Staging and committing a package. The signature checks live in `CRX3PackageTests`; what matters
/// here is what ends up on disk — and what does not, when a package is refused.
final class ExtensionPackageInstallerTests: XCTestCase {
    private var installRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let installRoot {
            try? FileManager.default.removeItem(at: installRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Staging

    func testStagesASignedPackageAndReportsItsPublisher() throws {
        let staged = try ExtensionPackageInstaller().stage(packageAt: try fixtureURL(named: "valid.crx"))
        defer { ExtensionPackageInstaller().discard(staged) }

        XCTAssertEqual(staged.format, .crx3)
        XCTAssertEqual(
            staged.signature,
            .verified(publisherIdentifier: "kliiopiebkklfgdplbapnchppieailka")
        )
        XCTAssertEqual(staged.identity.identifier.rawValue.count, 32)
        XCTAssertTrue(fileExists(staged.resourceBaseURL.appendingPathComponent("manifest.json")))
        XCTAssertTrue(fileExists(staged.resourceBaseURL.appendingPathComponent("assets/note.txt")))
    }

    func testUnwrapsASingleWrapperDirectory() throws {
        let staged = try ExtensionPackageInstaller().stage(packageAt: try fixtureURL(named: "nested.zip"))
        defer { ExtensionPackageInstaller().discard(staged) }

        XCTAssertEqual(staged.format, .zip)
        XCTAssertEqual(staged.signature, .unsigned(.plainArchive))
        XCTAssertEqual(staged.resourceBaseURL.lastPathComponent, "wrapper")
        XCTAssertTrue(fileExists(staged.resourceBaseURL.appendingPathComponent("manifest.json")))
    }

    func testIdenticalBytesProduceTheSameIdentifier() throws {
        let installer = ExtensionPackageInstaller()
        let first = try installer.stage(packageAt: try fixtureURL(named: "valid.crx"))
        defer { installer.discard(first) }
        let second = try installer.stage(packageAt: try fixtureURL(named: "valid.crx"))
        defer { installer.discard(second) }

        // The identifier is a content digest, which is what makes reinstall an update rather than
        // a second copy. Two stagings of the same file that disagreed would break that.
        XCTAssertEqual(first.identity.identifier, second.identity.identifier)
        XCTAssertEqual(first.identity.digest, second.identity.digest)
    }

    func testAPackageWithoutAManifestIsRejectedAndLeavesNothingBehind() throws {
        let before = stagingDirectoryCount()

        XCTAssertThrowsError(
            try ExtensionPackageInstaller().stage(packageAt: try fixtureURL(named: "no-manifest.zip"))
        ) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .manifestNotFound)
        }

        // This rejection happens after extraction, so it is the one that would strand a directory.
        XCTAssertEqual(stagingDirectoryCount(), before)
    }

    func testDiscardRemovesEverythingThatWasStaged() throws {
        let installer = ExtensionPackageInstaller()
        let staged = try installer.stage(packageAt: try fixtureURL(named: "valid.crx"))
        XCTAssertTrue(fileExists(staged.resourceBaseURL))

        installer.discard(staged)

        XCTAssertFalse(fileExists(staged.resourceBaseURL))
    }

    // MARK: - Committing

    func testCommitMovesTheExtensionUnderItsIdentifier() throws {
        let installer = ExtensionPackageInstaller()
        let staged = try installer.stage(packageAt: try fixtureURL(named: "valid.crx"))

        let installed = try installer.commit(staged, into: installRoot)

        XCTAssertEqual(installed.lastPathComponent, staged.identity.identifier.rawValue)
        XCTAssertTrue(fileExists(installed.appendingPathComponent("manifest.json")))
        // Staging is consumed, not copied: a leftover would be a second unprotected copy of the
        // same extension sitting in a temporary directory.
        XCTAssertFalse(fileExists(staged.stagingRoot))
    }

    func testCommitRefusesToOverwriteAnExistingInstall() throws {
        let installer = ExtensionPackageInstaller()
        let first = try installer.stage(packageAt: try fixtureURL(named: "valid.crx"))
        try installer.commit(first, into: installRoot)

        let second = try installer.stage(packageAt: try fixtureURL(named: "valid.crx"))
        XCTAssertThrowsError(try installer.commit(second, into: installRoot)) { error in
            XCTAssertEqual(
                error as? ExtensionInstallError,
                .packageAlreadyInstalled(second.identity.identifier.rawValue)
            )
        }
        // A refused commit still cleans up after itself.
        XCTAssertFalse(fileExists(second.stagingRoot))
    }

    func testCommitEnforcesTheInstalledExtensionLimit() throws {
        let installer = ExtensionPackageInstaller(maximumInstalledExtensions: 1)
        try FileManager.default.createDirectory(
            at: installRoot.appendingPathComponent("occupant", isDirectory: true),
            withIntermediateDirectories: true
        )
        let staged = try installer.stage(packageAt: try fixtureURL(named: "valid.crx"))

        XCTAssertThrowsError(try installer.commit(staged, into: installRoot)) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .tooManyInstalledExtensions(limit: 1))
        }
    }

    // MARK: - Helpers

    private func fixtureURL(named name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        guard let resourceURL = bundle.resourceURL else {
            throw XCTSkip("Test bundle has no resource URL.")
        }
        let url = resourceURL
            .appendingPathComponent("Fixtures/Packages", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Fixture \(name) is missing from the test bundle at \(url.path). Check the Tests/Fixtures folder reference in project.yml.")
            throw XCTSkip("Fixture \(name) not bundled.")
        }
        return url
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func stagingDirectoryCount() -> Int {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        return (contents ?? []).filter { $0.lastPathComponent.hasPrefix("ExtensionInstall-") }.count
    }
}
