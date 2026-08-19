import WebKit
import XCTest
@testable import ExtensionBrowser

/// M2 definition of done: load a bundled extension through `WKWebExtensionController` and print a
/// pass/fail table of what the runtime actually implements.
///
/// Spec §2.4 says the API matrix has to come from a real run, so nothing is asserted about which
/// APIs exist — that is the measurement. What *is* asserted is that the host wiring works: the
/// extension loads, its background content starts, the runtime calls back into our delegate, and
/// the report reaches the app over one of the two transports.
@MainActor
final class WebExtensionHarnessTests: XCTestCase {
    private var temporaryRoot: URL!
    private var host: WebExtensionHost!
    private var tabManager: TabManager!

    private static let harnessPageHost = "harness.kiwix.test"
    private static let harnessPageHTML = """
    <!doctype html>
    <html>
      <head><meta charset="utf-8"><title>KiwiX Harness Page</title></head>
      <body><main id="harness-body">content script target</main></body>
    </html>
    """

    override func setUp() async throws {
        try await super.setUp()

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KiwiXHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        // A non-persistent controller keeps extension storage out of the app container.
        host = WebExtensionHost(configuration: .nonPersistent())
        host.harnessChannel.enable()
        host.simulatedPageProvider = { url in
            url.host == Self.harnessPageHost ? Self.harnessPageHTML : nil
        }

        let configurationProvider = WebViewConfigurationProvider()
        configurationProvider.webExtensionHost = host
        tabManager = TabManager(
            webViewFactory: WebViewFactory(configurationProvider: configurationProvider),
            store: TabStore(fileURL: temporaryRoot.appendingPathComponent("tabs.json")),
            snapshotManager: TabSnapshotManager(
                store: TabSnapshotStore(
                    directoryURL: temporaryRoot.appendingPathComponent("Snapshots", isDirectory: true)
                )
            ),
            maximumWarmTabs: 3
        )

        host.attach(tabManager: tabManager)
        host.startSession()
        _ = try tabManager.createTab(url: nil, isPrivate: false, select: true)
    }

    override func tearDown() async throws {
        host?.unloadAll()
        host?.endSession()
        host = nil
        tabManager = nil
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
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

    // MARK: - Tests

    func testAPIHarnessReportsPassFailMatrix() async throws {
        let resourceBaseURL = try fixtureURL(named: "APIHarness")

        let reportArrived = expectation(description: "harness report delivered")
        var received: WebExtensionProbeReport?
        host.harnessChannel.onReport = { report in
            received = report
            reportArrived.fulfill()
        }

        let context = try await host.loadExtension(
            resourceBaseURL: resourceBaseURL,
            policy: .trustFirstPartyBundle
        )

        // Evidence the manifest was understood, independent of anything the JavaScript reports.
        let webExtension = context.webExtension
        XCTAssertEqual(webExtension.manifestVersion, 3, "Harness must load as MV3.")
        XCTAssertTrue(webExtension.hasBackgroundContent, "Harness declares a background script.")
        XCTAssertFalse(
            webExtension.hasPersistentBackgroundContent,
            "Harness declares persistent:false; a persistent page would mean the flag was ignored."
        )
        XCTAssertTrue(context.hasInjectedContent, "Harness declares a content script.")
        XCTAssertTrue(context.hasAccessToAllHosts, "trustFirstPartyBundle should grant <all_urls>.")
        // Measured, not asserted: whether static DNR rulesets are honoured is part of the matrix.
        print("hasContentModificationRules=\(context.hasContentModificationRules)")

        if !webExtension.errors.isEmpty {
            print("WKWebExtension load errors: \(webExtension.errors.map(\.localizedDescription))")
        }
        if let unsupported = context.unsupportedAPIs, !unsupported.isEmpty {
            print("WKWebExtensionContext.unsupportedAPIs: \(unsupported.sorted().joined(separator: ", "))")
        }

        try await host.loadBackgroundContent(for: context)
        await fulfillment(of: [reportArrived], timeout: 90)

        let report = try XCTUnwrap(received, "No probe report arrived over either transport.")
        print(report.consoleTable())
        print("Delegate callbacks observed: \(host.delegateCalls.summary)")

        if let json = try? JSONEncoder().encode(report) {
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = "webextension-api-matrix.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let tableAttachment = XCTAttachment(string: report.consoleTable())
        tableAttachment.name = "webextension-api-matrix.txt"
        tableAttachment.lifetime = .keepAlways
        add(tableAttachment)

        XCTAssertFalse(report.probes.isEmpty, "Harness produced no probes.")
        XCTAssertGreaterThan(report.passCount, 0, "Nothing passed — the runtime is not usable.")

        // The tab adapter is the risky part of §5, so its round trip is asserted rather than
        // merely reported.
        XCTAssertTrue(
            host.delegateCalls.called("openNewTabUsing"),
            "The runtime never asked us to open a tab; tabs.create did not reach the delegate."
        )
        let tabsCreate = report.probes.first { $0.id == "tabs.create" }
        XCTAssertEqual(tabsCreate?.status, .pass, "tabs.create failed: \(tabsCreate?.detail ?? "no probe")")
        let tabsQuery = report.probes.first { $0.id == "tabs.query" }
        XCTAssertEqual(tabsQuery?.status, .pass, "tabs.query failed: \(tabsQuery?.detail ?? "no probe")")
    }

    /// Spec §2.4 asks whether MV3 `background.service_worker` is usable. This answers it without
    /// putting the main harness at risk.
    func testServiceWorkerBackgroundLoadability() async throws {
        let resourceBaseURL = try fixtureURL(named: "ServiceWorkerProbe")

        do {
            let context = try await host.loadExtension(
                resourceBaseURL: resourceBaseURL,
                policy: .trustFirstPartyBundle
            )
            print("service_worker: WKWebExtension accepted the manifest.")
            print("service_worker: hasBackgroundContent=\(context.webExtension.hasBackgroundContent)")
            print("service_worker: errors=\(context.webExtension.errors.map(\.localizedDescription))")
            do {
                try await host.loadBackgroundContent(for: context)
                print("service_worker: background content started.")
            } catch {
                print("service_worker: background content failed to start — \(error.localizedDescription)")
            }
        } catch {
            print("service_worker: WKWebExtension rejected the manifest — \(error.localizedDescription)")
        }
    }
}
