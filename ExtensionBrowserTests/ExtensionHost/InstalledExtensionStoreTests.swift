import XCTest
@testable import ExtensionBrowser

/// The catalog is the authority on what the user agreed to, so these tests care less about storage
/// mechanics than about what a hostile or damaged file can talk the store into.
final class InstalledExtensionStoreTests: XCTestCase {
    private var directory: URL!
    private var catalogURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        catalogURL = directory.appendingPathComponent("Extensions-v1.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Round trip

    func testLoadReturnsEmptyBeforeAnythingIsInstalled() async throws {
        let store = InstalledExtensionStore(fileURL: catalogURL)
        let records = try await store.load()
        XCTAssertTrue(records.isEmpty)
    }

    func testRoundTripsARecordAndKeepsGrantedSetsSorted() async throws {
        let store = InstalledExtensionStore(fileURL: catalogURL)
        try await store.upsert(
            record(
                permissions: ["tabs", "storage", "activeTab"],
                patterns: ["https://z.example/*", "https://a.example/*"]
            )
        )

        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].grantedPermissions, ["activeTab", "storage", "tabs"])
        XCTAssertEqual(loaded[0].grantedMatchPatterns, ["https://a.example/*", "https://z.example/*"])
        XCTAssertTrue(loaded[0].isEnabled)
        XCTAssertTrue(loaded[0].isSignatureVerified)
    }

    func testWritingIdenticalStateProducesIdenticalBytes() async throws {
        let store = InstalledExtensionStore(fileURL: catalogURL)
        try await store.replaceAll([record(permissions: ["b", "a"], patterns: ["https://b/*", "https://a/*"])])
        let first = try Data(contentsOf: catalogURL)

        try await store.replaceAll([record(permissions: ["a", "b"], patterns: ["https://a/*", "https://b/*"])])
        let second = try Data(contentsOf: catalogURL)

        // Sets encode in hash order; sorted arrays do not. Without this the file churns on every
        // save and a diff of the catalog tells you nothing.
        XCTAssertEqual(first, second)
    }

    // MARK: - Mutation

    func testUpsertReplacesTheRecordWithTheSameIdentifier() async throws {
        let store = InstalledExtensionStore(fileURL: catalogURL)
        try await store.upsert(record(permissions: ["storage"], patterns: []))
        try await store.upsert(record(displayName: "Renamed", permissions: ["tabs"], patterns: []))

        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].displayName, "Renamed")
        XCTAssertEqual(loaded[0].grantedPermissions, ["tabs"])
    }

    func testEnableDisableAndRemove() async throws {
        let store = InstalledExtensionStore(fileURL: catalogURL)
        try await store.upsert(record())

        var loaded = try await store.setEnabled(false, for: identifier)
        XCTAssertFalse(loaded[0].isEnabled)

        loaded = try await store.remove(identifier: identifier)
        XCTAssertTrue(loaded.isEmpty)

        do {
            _ = try await store.remove(identifier: identifier)
            XCTFail("Removing an extension that is not installed should fail.")
        } catch {
            XCTAssertEqual(error as? InstalledExtensionStoreError, .notInstalled(identifier))
        }
    }

    func testUpsertRefusesToGrowPastTheInstalledLimit() async throws {
        let store = InstalledExtensionStore(fileURL: catalogURL)
        let limit = SafePersistence.maximumInstalledExtensionCount
        for index in 0..<limit {
            try await store.upsert(record(identifier: hexIdentifier(index)))
        }

        do {
            _ = try await store.upsert(record(identifier: hexIdentifier(limit)))
            XCTFail("The catalog must not grow past its limit.")
        } catch {
            XCTAssertEqual(
                error as? ExtensionInstallError,
                .tooManyInstalledExtensions(limit: limit)
            )
        }
    }

    // MARK: - Hostile and damaged input

    func testRecordsWithUnusableIdentifiersAreDropped() async throws {
        let store = InstalledExtensionStore(fileURL: catalogURL)
        // No directory can be named by these, so there is nothing for the record to point at.
        try await store.replaceAll([
            record(identifier: "not-a-digest"),
            record(identifier: String(repeating: "A", count: 32)),
            record(identifier: identifier)
        ])

        let loaded = try await store.load()
        XCTAssertEqual(loaded.map(\.identifier), [identifier])
    }

    func testUnsafeDisplayNamesAndPermissionStringsAreNeutralised() async throws {
        let store = InstalledExtensionStore(fileURL: catalogURL)
        try await store.replaceAll([
            record(
                displayName: "   ",
                permissions: ["storage", "line\nbreak", String(repeating: "x", count: 4_096)],
                patterns: ["https://ok.example/*"]
            )
        ])

        let loaded = try await store.load()
        // An empty name falls back to the identifier rather than rendering as a blank row that a
        // user cannot tell apart from another blank row.
        XCTAssertEqual(loaded[0].displayName, identifier)
        // A permission string is compared against a runtime value, so it is kept whole or dropped.
        XCTAssertEqual(loaded[0].grantedPermissions, ["storage"])
        XCTAssertEqual(loaded[0].grantedMatchPatterns, ["https://ok.example/*"])
    }

    func testUnsupportedSchemaIsQuarantinedAndReported() async throws {
        let payload = """
        {"schemaVersion":99,"extensions":[]}
        """
        try Data(payload.utf8).write(to: catalogURL, options: [.atomic])
        let store = InstalledExtensionStore(fileURL: catalogURL)

        do {
            _ = try await store.load()
            XCTFail("A catalog from a future schema must not be read.")
        } catch {
            XCTAssertEqual(error as? InstalledExtensionStoreError, .unsupportedSchema(99))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(siblings.contains { $0.lastPathComponent.contains(".corrupt-") })
    }

    func testAMutationRecoversFromAnUnreadableCatalog() async throws {
        try Data("{ this is not json".utf8).write(to: catalogURL, options: [.atomic])
        let store = InstalledExtensionStore(fileURL: catalogURL)

        // The bad file is quarantined by the failed read, so the write lands on a clean slate
        // instead of leaving the user permanently unable to install anything.
        let records = try await store.upsert(record())

        XCTAssertEqual(records.map(\.identifier), [identifier])
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.count, 1)
    }

    // MARK: - Policy bridge

    func testRecordMapsToAUserGrantedPolicy() {
        let policy = record(permissions: ["storage"], patterns: ["https://a/*"]).permissionPolicy

        XCTAssertEqual(
            policy,
            .userGranted(permissions: ["storage"], matchPatterns: ["https://a/*"])
        )
        // Only a first-party bundle answers runtime prompts on its own.
        XCTAssertFalse(policy.autoGrantsRuntimePrompts)
    }

    // MARK: - Helpers

    private var identifier: String { hexIdentifier(0) }

    private func hexIdentifier(_ index: Int) -> String {
        let suffix = String(format: "%04x", index)
        return String(repeating: "a", count: 32 - suffix.count) + suffix
    }

    private func record(
        identifier: String? = nil,
        displayName: String = "Fixture Extension",
        permissions: Set<String> = ["storage"],
        patterns: Set<String> = ["https://example.com/*"]
    ) -> InstalledExtensionRecord {
        InstalledExtensionRecord(
            identifier: identifier ?? self.identifier,
            displayName: displayName,
            format: ExtensionPackage.Format.crx3.rawValue,
            publisherIdentifier: "kliiopiebkklfgdplbapnchppieailka",
            isSignatureVerified: true,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isEnabled: true,
            grantedPermissions: permissions.sorted(),
            grantedMatchPatterns: patterns.sorted()
        )
    }
}
