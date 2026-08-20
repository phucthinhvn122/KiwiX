import WebKit
import XCTest
@testable import ExtensionBrowser

/// The install flow as a whole: file in, consent, catalog entry, loaded context — and the same in
/// reverse. The pieces have their own tests; what is asserted here is that they agree with each
/// other, especially that the catalog and the runtime never disagree about what is running.
@MainActor
final class ExtensionInstallCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var host: WebExtensionHost!
    private var coordinator: ExtensionInstallCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host = WebExtensionHost(configuration: .nonPersistent())
        coordinator = makeCoordinator(host: host)
    }

    override func tearDown() async throws {
        host?.unloadAll()
        host = nil
        coordinator = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    // MARK: - Preparing

    func testPreparingASignedPackageReportsItsPublisherAndWhatItAsksFor() async throws {
        let prepared = try await coordinator.prepare(fileURL: try fixtureURL(named: "valid.crx"))
        defer { coordinator.cancel(prepared) }

        XCTAssertFalse(prepared.requiresExplicitTrust)
        XCTAssertEqual(prepared.publisherIdentifier, "kliiopiebkklfgdplbapnchppieailka")
        XCTAssertEqual(prepared.summary.permissions, ["storage"])
        XCTAssertFalse(prepared.summary.requestsAllURLs)
        XCTAssertFalse(prepared.summary.hasUnsafeDisplayName)
        XCTAssertFalse(prepared.summary.displayName.isEmpty)
        // The manifest asks for one host, so the sheet must have something to show under site access.
        XCTAssertTrue(
            prepared.summary.matchPatterns.contains { $0.contains("example.com") },
            "Expected the host permission to survive into the summary, got \(prepared.summary.matchPatterns)"
        )
    }

    func testAnUnsignedPackageDemandsExplicitTrust() async throws {
        let prepared = try await coordinator.prepare(fileURL: try fixtureURL(named: "unsigned.zip"))
        defer { coordinator.cancel(prepared) }

        // §7: this is the flag the sheet turns into a banner plus a second confirmation.
        XCTAssertTrue(prepared.requiresExplicitTrust)
        XCTAssertNil(prepared.publisherIdentifier)
    }

    func testPreparingAPackageWithoutAManifestFails() async throws {
        do {
            _ = try await coordinator.prepare(fileURL: try fixtureURL(named: "no-manifest.zip"))
            XCTFail("A package with no manifest is not an extension.")
        } catch {
            XCTAssertEqual(error as? ExtensionInstallError, .manifestNotFound)
        }
    }

    func testCancellingLeavesNothingStagedAndNothingInstalled() async throws {
        let prepared = try await coordinator.prepare(fileURL: try fixtureURL(named: "valid.crx"))
        let stagingRoot = prepared.staged.stagingRoot
        XCTAssertTrue(fileExists(stagingRoot))

        coordinator.cancel(prepared)

        XCTAssertFalse(fileExists(stagingRoot))
        XCTAssertTrue(coordinator.records.isEmpty)
        XCTAssertTrue(host.loadedContexts.isEmpty)
    }

    // MARK: - Installing

    func testInstallingRecordsTheGrantAndLoadsTheExtension() async throws {
        let prepared = try await coordinator.prepare(fileURL: try fixtureURL(named: "valid.crx"))
        let identifier = prepared.staged.identity.identifier.rawValue
        let expectedPatterns = prepared.summary.matchPatterns

        try await coordinator.install(prepared)

        XCTAssertEqual(coordinator.records.map(\.identifier), [identifier])
        let record = try XCTUnwrap(coordinator.records.first)
        XCTAssertTrue(record.isEnabled)
        XCTAssertTrue(record.isSignatureVerified)
        XCTAssertEqual(record.grantedPermissions, ["storage"])
        XCTAssertEqual(record.grantedMatchPatterns, expectedPatterns)
        XCTAssertTrue(fileExists(installRoot.appendingPathComponent(identifier)))

        let context = try XCTUnwrap(host.loadedContext(uniqueIdentifier: identifier))
        // Never `trustFirstPartyBundle`: an installed package answers no runtime prompt on its own.
        XCTAssertEqual(
            host.policy(for: context),
            .userGranted(
                permissions: ["storage"],
                matchPatterns: Set(expectedPatterns)
            )
        )
        XCTAssertFalse(host.policy(for: context).autoGrantsRuntimePrompts)
    }

    func testInstallingConsumesTheStagingDirectory() async throws {
        let prepared = try await coordinator.prepare(fileURL: try fixtureURL(named: "valid.crx"))
        let stagingRoot = prepared.staged.stagingRoot

        try await coordinator.install(prepared)

        XCTAssertFalse(fileExists(stagingRoot))
    }

    // MARK: - Enabling, disabling, removing

    func testDisablingUnloadsAndEnablingLoadsAgain() async throws {
        let identifier = try await installValidPackage()

        try await coordinator.setEnabled(false, for: identifier)
        XCTAssertNil(host.loadedContext(uniqueIdentifier: identifier))
        XCTAssertEqual(coordinator.records.first?.isEnabled, false)
        // Disabling is not uninstalling: the files stay, so re-enabling costs nothing.
        XCTAssertTrue(fileExists(installRoot.appendingPathComponent(identifier)))

        try await coordinator.setEnabled(true, for: identifier)
        XCTAssertNotNil(host.loadedContext(uniqueIdentifier: identifier))
        XCTAssertEqual(coordinator.records.first?.isEnabled, true)
    }

    func testRemovingTakesTheFilesTheCatalogEntryAndTheContext() async throws {
        let identifier = try await installValidPackage()

        try await coordinator.remove(identifier: identifier)

        XCTAssertTrue(coordinator.records.isEmpty)
        XCTAssertNil(host.loadedContext(uniqueIdentifier: identifier))
        XCTAssertFalse(fileExists(installRoot.appendingPathComponent(identifier)))
    }

    // MARK: - Restoring

    func testRestoreLoadsWhatTheCatalogSaysIsEnabled() async throws {
        let identifier = try await installValidPackage()

        // A second launch: the first controller lets go first, then a fresh host and coordinator
        // find the same files on disk.
        host.unloadAll()
        let secondHost = WebExtensionHost(configuration: .nonPersistent())
        let secondCoordinator = makeCoordinator(host: secondHost)
        await secondCoordinator.restore()

        XCTAssertEqual(secondCoordinator.records.map(\.identifier), [identifier])
        XCTAssertNotNil(secondHost.loadedContext(uniqueIdentifier: identifier))
        secondHost.unloadAll()
    }

    func testRestoreSkipsWhatTheUserTurnedOff() async throws {
        let identifier = try await installValidPackage()
        try await coordinator.setEnabled(false, for: identifier)

        host.unloadAll()
        let secondHost = WebExtensionHost(configuration: .nonPersistent())
        let secondCoordinator = makeCoordinator(host: secondHost)
        await secondCoordinator.restore()

        XCTAssertEqual(secondCoordinator.records.count, 1)
        XCTAssertTrue(secondHost.loadedContexts.isEmpty)
        secondHost.unloadAll()
    }

    // MARK: - Helpers

    private var installRoot: URL {
        directory.appendingPathComponent("Extensions", isDirectory: true)
    }

    private func makeCoordinator(host: WebExtensionHost) -> ExtensionInstallCoordinator {
        ExtensionInstallCoordinator(
            host: host,
            store: InstalledExtensionStore(
                fileURL: directory.appendingPathComponent("Extensions-v1.json", isDirectory: false)
            ),
            installRootURL: installRoot
        )
    }

    @discardableResult
    private func installValidPackage() async throws -> String {
        let prepared = try await coordinator.prepare(fileURL: try fixtureURL(named: "valid.crx"))
        let identifier = prepared.staged.identity.identifier.rawValue
        try await coordinator.install(prepared)
        return identifier
    }

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
}
