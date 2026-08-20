import WebKit
import XCTest
@testable import ExtensionBrowser

/// M4 turned the host from "load the bundled harness once" into "load whatever the user installed,
/// and take it away again". These tests cover that bookkeeping — not the permission plumbing, which
/// belongs to WebKit and is asserted through the policy type instead.
@MainActor
final class WebExtensionHostRegistryTests: XCTestCase {
    private var host: WebExtensionHost!

    override func setUp() async throws {
        try await super.setUp()
        // Non-persistent: nothing this test loads should survive into the app container.
        host = WebExtensionHost(configuration: .nonPersistent())
    }

    override func tearDown() async throws {
        host?.unloadAll()
        host = nil
        try await super.tearDown()
    }

    func testLoadedContextIsFoundByItsAssignedIdentifier() async throws {
        let identifier = "kiwix.test.registry-one"
        let context = try await host.loadExtension(
            resourceBaseURL: try fixtureURL(named: "APIHarness"),
            policy: .denyAll,
            uniqueIdentifier: identifier
        )

        XCTAssertEqual(context.uniqueIdentifier, identifier)
        XCTAssertIdentical(host.loadedContext(uniqueIdentifier: identifier), context)
        XCTAssertNil(host.loadedContext(uniqueIdentifier: "kiwix.test.absent"))
        XCTAssertEqual(host.loadedContexts.count, 1)
    }

    func testUnloadingOneExtensionLeavesTheOthersAlone() async throws {
        let first = try await host.loadExtension(
            resourceBaseURL: try fixtureURL(named: "APIHarness"),
            policy: .denyAll,
            uniqueIdentifier: "kiwix.test.first"
        )
        let second = try await host.loadExtension(
            resourceBaseURL: try fixtureURL(named: "NetworkProbe"),
            policy: .userGranted(permissions: ["storage"], matchPatterns: []),
            uniqueIdentifier: "kiwix.test.second"
        )
        XCTAssertEqual(host.loadedContexts.count, 2)

        host.unload(first)

        XCTAssertEqual(host.loadedContexts.count, 1)
        XCTAssertNil(host.loadedContext(uniqueIdentifier: "kiwix.test.first"))
        XCTAssertIdentical(host.loadedContext(uniqueIdentifier: "kiwix.test.second"), second)
        XCTAssertEqual(
            host.policy(for: second),
            .userGranted(permissions: ["storage"], matchPatterns: [])
        )
    }

    func testPolicyForAnUnknownContextDeniesEverything() async throws {
        let context = try await host.loadExtension(
            resourceBaseURL: try fixtureURL(named: "APIHarness"),
            policy: .trustFirstPartyBundle,
            uniqueIdentifier: "kiwix.test.forgotten"
        )
        XCTAssertEqual(host.policy(for: context), .trustFirstPartyBundle)

        host.unload(context)

        // The fallback matters: a context the host has forgotten must not keep answering runtime
        // prompts as though it were still trusted.
        XCTAssertEqual(host.policy(for: context), .denyAll)
        XCTAssertFalse(host.policy(for: context).autoGrantsRuntimePrompts)
    }

    // MARK: - Fixtures

    private func fixtureURL(named name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        guard let resourceURL = bundle.resourceURL else {
            throw XCTSkip("Test bundle has no resource URL.")
        }
        let url = resourceURL
            .appendingPathComponent("Fixtures/WebExtensions", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
            XCTFail("Fixture \(name) is missing from the test bundle at \(url.path). Check the Tests/Fixtures folder reference in project.yml.")
            throw XCTSkip("Fixture \(name) not bundled.")
        }
        return url
    }
}
