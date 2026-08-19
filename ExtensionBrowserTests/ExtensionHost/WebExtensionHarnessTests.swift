import UIKit
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

    /// Deliberately not a UUID: if the runtime ignored the assignment and fell back to its own
    /// default, the probe detail would still *look* like a plausible id and the test would pass.
    private static let pinnedIdentifier = "kiwix.harness.pinned-identity"

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

    // MARK: - Reporting

    /// Sorted keys so a diff between two runs shows behaviour changes, not key ordering.
    private static let reportEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Facts about the run that only the host can state truthfully (DECISIONS §4.2.3).
    private static func hostEnvironment(for webExtension: WKWebExtension) -> [String: String] {
        var machine = utsname()
        uname(&machine)
        // `String(cString:)` is deprecated in Swift 6; decode the NUL-terminated bytes directly.
        let identifier = withUnsafeBytes(of: machine.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }

        #if targetEnvironment(simulator)
        let isSimulator = "true"
        #else
        let isSimulator = "false"
        #endif

        return [
            "osVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model,
            "hardwareIdentifier": identifier,
            // §4.2.10: a green matrix on the simulator is a smoke test, not a device result.
            "isSimulator": isSimulator,
            "extensionVersion": webExtension.version ?? "unknown",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }

    /// §4.2.4 wants a stable JSON artifact on disk in addition to the xcresult attachment, so the
    /// matrix survives even when the test crashes before attachments are flushed.
    private func writeReportJSON(_ report: WebExtensionProbeReport) throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("KiwiXHarness", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appendingPathComponent("webextension-api-matrix.json")
        try Self.reportEncoder.encode(report).write(to: url, options: .atomic)
        return url.path
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
            policy: .trustFirstPartyBundle,
            uniqueIdentifier: Self.pinnedIdentifier
        )

        // The default identifier is a fresh UUID per install, so anything the app keys on it is lost
        // on reinstall. Apple documents `uniqueIdentifier` as settable while unloaded and surfaced as
        // `browser.runtime.id`; this asserts that documented behaviour instead of trusting it.
        XCTAssertEqual(
            context.uniqueIdentifier,
            Self.pinnedIdentifier,
            "Assigning uniqueIdentifier before load did not stick."
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

        try await host.loadBackgroundContent(for: context, timeout: 15)
        // 15s + 30s stays under the 60s per-test allowance the Makefile passes to xcodebuild.
        // Inside that the harness budgets 8s for the content-script ping, 5s for the native
        // handshake, and self-destructs at 20s so a hung probe still ships a partial matrix.
        await fulfillment(of: [reportArrived], timeout: 30)

        var report = try XCTUnwrap(received, "No probe report arrived over either transport.")
        // DECISIONS §4.2.3: the host owns the facts JavaScript cannot be trusted to report.
        report.environment.merge(Self.hostEnvironment(for: webExtension)) { _, host in host }

        let jsonPath = try writeReportJSON(report)
        print(report.markerLine(jsonPath: jsonPath))
        print(report.consoleTable())
        print("Delegate callbacks observed: \(host.delegateCalls.summary)")

        if let json = try? Self.reportEncoder.encode(report) {
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
        XCTAssertGreaterThan(
            report.passCount,
            0,
            "Nothing passed — the runtime is not usable. Feature detection alone reports "
                + "\(report.availableCount) available probes, which proves nothing."
        )

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

        // The host-side assertion above only proves the property took the value. This proves the
        // value actually reaches the extension as `browser.runtime.id`, which is the part that
        // decides whether a stable install identity is possible at all (risk R-20).
        let runtimeID = report.probes.first { $0.id == "runtime.id" }
        XCTAssertEqual(
            runtimeID?.detail,
            Self.pinnedIdentifier,
            "browser.runtime.id did not report the identifier the app assigned; a stable install "
                + "identity is not achievable this way."
        )
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
            // A manifest the runtime cannot start never calls the completion handler, so the
            // previous version of this test hung until xcodebuild killed it at 60s. The timeout
            // turns "never starts" into a reportable result.
            do {
                try await host.loadBackgroundContent(for: context, timeout: 15)
                print("service_worker: background content started.")
            } catch let error as WebExtensionHostError {
                if case .backgroundContentTimedOut = error {
                    print("service_worker: background content never started (no callback in 15s).")
                } else {
                    print("service_worker: background content failed — \(error.localizedDescription)")
                }
            } catch {
                print("service_worker: background content failed — \(error.localizedDescription)")
            }
        } catch {
            print("service_worker: WKWebExtension rejected the manifest — \(error.localizedDescription)")
        }
    }
}
