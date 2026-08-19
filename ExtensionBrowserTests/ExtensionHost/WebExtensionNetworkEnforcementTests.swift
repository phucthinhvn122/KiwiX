import UIKit
import WebKit
import XCTest
@testable import ExtensionBrowser

enum ControlRuleListError: Error, LocalizedError {
    case compiledToNil

    var errorDescription: String? {
        "WKContentRuleListStore reported neither a compiled rule list nor an error."
    }
}

/// Retains the navigation callbacks: `WKWebView.navigationDelegate` is weak, so an inline delegate
/// would be deallocated before the first callback.
@MainActor
final class NavigationSettledWaiter: NSObject, WKNavigationDelegate {
    var onSettled: ((Error?) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onSettled?(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onSettled?(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        onSettled?(error)
    }
}

/// M3: does `declarativeNetRequest` actually suppress a request, or does WebKit merely accept the
/// rules without enforcing them?
///
/// M2 could not tell the difference and said so — the harness reports the API as present, which
/// DECISIONS §4.2.5 explicitly refuses to count as a pass. What makes an answer here falsifiable:
///
///   * A project-controlled server on `127.0.0.1`. Loopback needs no DNS, so a request that never
///     arrives was suppressed; it cannot be a name that failed to resolve. That confound is why
///     the M2 fixture (`blocked.kiwix.test`) could not be used as evidence.
///   * A **baseline** phase with no extension loaded, proving the subresources are fetched
///     normally. Without it, absence proves nothing.
///   * Ordering. `allowed.js` is last in every page, so its arrival proves the earlier scripts had
///     already been offered to the network stack.
///
/// Run 32233216520 measured "rules installed, nothing blocked" 392 ms after the extension reported
/// its rules ready. That is not yet a conclusion, because two explanations survived it, and both
/// were mine to rule out rather than WebKit's to answer:
///
///   * **Timing** — `WKContentRuleList` compilation is asynchronous and 392 ms may simply be too
///     soon. The `late` phase repeats the identical navigation after a deliberate delay.
///   * **Loopback exemption** — if WebKit applies no content blocking at all to `127.0.0.1`, the
///     whole apparatus measures nothing. The `control` phase compiles a `WKContentRuleList`
///     directly through `WKContentRuleListStore`, the same machinery WebKit's own DNR support is
///     built on, and attaches it to a web view built by the shipping factory. If that blocks while
///     the extension's rules do not, loopback is exonerated and the defect is specific to the
///     `WKWebExtension` path.
@MainActor
final class WebExtensionNetworkEnforcementTests: XCTestCase {
    private var temporaryRoot: URL!
    private var host: WebExtensionHost!
    private var tabManager: TabManager!
    private var server: LocalHTTPServer!
    private var port: UInt16 = 0
    private var window: UIWindow!
    private var waiters: [NavigationSettledWaiter] = []
    private var compiledRuleListIdentifier: String?

    /// `allowed.js` last: the order is the argument, not a detail.
    ///
    /// A 2x2 over {bare substring, substring containing a dot} x {our rule list, the extension's
    /// DNR rules}. Run 32234424615 left exactly one uncontrolled difference between the working
    /// control and the failing treatment -- the control's filter had no dot in it -- and a bug
    /// report with that hole in it deserves to be rejected.
    private static let subresources = [
        "blocked-static.js",   // DNR static rule, filter "blocked-static.js" (dotted)
        "blocked-dynamic.js",  // DNR dynamic rule, filter "blocked-dynamic.js" (dotted)
        "blocked-nodot.js",    // DNR static rule, filter "blocked-nodot" (bare)
        "blocked-control.js",  // our rule list, url-filter "blocked-control" (bare)
        "blocked-ctldot.js",   // our rule list, url-filter "blocked-ctldot.js" (dotted)
        "allowed.js"
    ]
    private static let phases = ["baseline", "early", "late", "control"]

    /// How long to let WebKit finish compiling before the second attempt. Long enough that
    /// "compilation had not finished" stops being a credible reading of the result.
    private static let compilationGrace: TimeInterval = 8

    override func setUp() async throws {
        try await super.setUp()

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KiwiXEnforcement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        server = try LocalHTTPServer()
        for phase in Self.phases {
            server.route(
                "/\(phase).html",
                contentType: "text/html; charset=utf-8",
                body: Self.pageHTML(phase: phase)
            )
            for name in Self.subresources {
                server.route(
                    "/\(phase)/\(name)",
                    contentType: "application/javascript; charset=utf-8",
                    body: "/* \(phase)/\(name) */"
                )
            }
        }
        port = try await server.start()

        // A non-persistent controller keeps extension storage out of the app container.
        host = WebExtensionHost(configuration: .nonPersistent())
        host.harnessChannel.enable()

        // The production wiring, not a bespoke one: rules only have a chance to apply to a web view
        // the controller knows about, and the controller only learns about tabs through TabManager.
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

        // Off-screen but real: the shipping app never runs a detached web view.
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        for subview in window?.subviews ?? [] {
            (subview as? WKWebView)?.stopLoading()
            (subview as? WKWebView)?.navigationDelegate = nil
            subview.removeFromSuperview()
        }
        waiters.removeAll()
        window?.isHidden = true
        window = nil
        server?.stop()
        server = nil
        host?.harnessChannel.onHandshake = nil
        host?.unloadAll()
        host?.endSession()
        host = nil
        tabManager = nil

        // Compiled rule lists live in a store on disk, so leaving one behind would leak state into
        // the next run of this suite.
        if let identifier = compiledRuleListIdentifier, let store = WKContentRuleListStore.default() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
            }
        }
        compiledRuleListIdentifier = nil

        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
    }

    // MARK: - Fixture

    private static func pageHTML(phase: String) -> String {
        let tags = subresources
            .map { "    <script src=\"/\(phase)/\($0)\"></script>" }
            .joined(separator: "\n")
        return """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>KiwiX enforcement \(phase)</title></head>
          <body>
        \(tags)
            <main id="enforcement">\(phase)</main>
          </body>
        </html>
        """
    }

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

    // MARK: - Navigation

    private func makeTabWebView() throws -> WKWebView {
        let tab = try tabManager.createTab(url: nil, isPrivate: false, select: true)
        let webView = try XCTUnwrap(tab.webView, "TabManager.activate should have materialized a web view.")
        window.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: window.topAnchor),
            webView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: window.bottomAnchor)
        ])
        window.layoutIfNeeded()
        return webView
    }

    private func load(_ path: String, in webView: WKWebView, timeout: TimeInterval = 30) async throws {
        let waiter = NavigationSettledWaiter()
        waiters.append(waiter)
        webView.navigationDelegate = waiter

        let settled = expectation(description: "navigation settled: \(path)")
        let gate = ResumeOnce()
        var failure: Error?
        waiter.onSettled = { error in
            guard gate.claim() else { return }
            failure = error
            settled.fulfill()
        }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        await fulfillment(of: [settled], timeout: timeout)

        if let failure {
            throw failure
        }
    }

    /// Loads one phase page and returns once its last subresource has arrived or the wait expires.
    /// The return value is only "did the trailing allowed script make it", which is the guard every
    /// negative assertion in this file depends on.
    @discardableResult
    private func runPhase(_ phase: String, in webView: WKWebView) async throws -> Bool {
        try await load("/\(phase).html", in: webView)
        return await waitForRequest("/\(phase)/allowed.js")
    }

    /// Bounded chance for a path to arrive before a negative assertion may conclude it never will.
    private func waitForRequest(_ path: String, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if server.received(path) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return server.received(path)
    }

    // MARK: - Positive control

    /// Compiles a block rule with `WKContentRuleListStore` — public API, and the same content-rule
    /// machinery WebKit's `declarativeNetRequest` support is implemented on top of.
    private func compileControlRuleList() async throws -> WKContentRuleList {
        let identifier = "kiwix-enforcement-control-\(UUID().uuidString)"
        let store = try XCTUnwrap(
            WKContentRuleListStore.default(),
            "No default content rule list store; the positive control cannot run."
        )
        // Two triggers, matching the two filter forms the extension's rules use, so the control
        // and the treatment differ only in who supplied the rule.
        let bare = #"{"trigger":{"url-filter":"blocked-control","resource-type":["script"]},"action":{"type":"block"}}"#
        let dotted = #"{"trigger":{"url-filter":"blocked-ctldot.js","resource-type":["script"]},"action":{"type":"block"}}"#
        let json = "[\(bare),\(dotted)]"

        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: ControlRuleListError.compiledToNil)
                }
            }
        }
        compiledRuleListIdentifier = identifier
        return list
    }

    // MARK: - Tests

    func testDeclarativeNetRequestSuppressesARealRequest() async throws {
        let probeURL = try fixtureURL(named: "NetworkProbe")

        // ---- Phase 1: baseline. No extension loaded, so every subresource must arrive.
        let baselineWebView = try makeTabWebView()
        try await runPhase("baseline", in: baselineWebView)

        for name in Self.subresources {
            XCTAssertTrue(
                server.received("/baseline/\(name)"),
                "/baseline/\(name) was not fetched even with no extension loaded, so its later "
                    + "absence would prove nothing about blocking. Observed: \(server.requestedPaths)"
            )
        }

        // ---- Load the probe and wait until its rules genuinely exist.
        let ready = expectation(description: "network probe installed its rules")
        let readyGate = ResumeOnce()
        var readySignal: [String: Any]?
        var matchedSignal: [String: Any]?
        var observedByWebRequest: [String] = []
        host.harnessChannel.onHandshake = { payload in
            switch payload["phase"] as? String {
            case "ready":
                readySignal = payload
                if readyGate.claim() { ready.fulfill() }
            case "matched":
                if matchedSignal == nil { matchedSignal = payload }
            case "webRequest":
                if let url = payload["url"] as? String { observedByWebRequest.append(url) }
            default:
                break
            }
        }

        let context = try await host.loadExtension(
            resourceBaseURL: probeURL,
            policy: .trustFirstPartyBundle,
            uniqueIdentifier: "kiwix.network-probe"
        )
        try await host.loadBackgroundContent(for: context, timeout: 15)
        await fulfillment(of: [ready], timeout: 20)

        let signal = try XCTUnwrap(readySignal, "The probe never reported that its rules were installed.")
        print("KIWIX_DNR_PROBE_READY \(signal)")
        print("KIWIX_DNR_CONTEXT hasContentModificationRules=\(context.hasContentModificationRules) "
            + "hasAccessToAllHosts=\(context.hasAccessToAllHosts)")

        XCTAssertTrue(
            context.hasContentModificationRules,
            "WebKit did not register any content modification rules for a manifest that declares a "
                + "static ruleset and a dynamic rule, so there is nothing to enforce."
        )

        // ---- Phase 2: immediately after the rules are reported ready.
        let earlyWebView = try makeTabWebView()
        let earlyAllowedArrived = try await runPhase("early", in: earlyWebView)
        let earlyStaticBlocked = !server.received("/early/blocked-static.js")
        let earlyDynamicBlocked = !server.received("/early/blocked-dynamic.js")
        let earlyBareBlocked = !server.received("/early/blocked-nodot.js")

        // ---- Phase 3: the identical navigation, after a deliberate compilation grace period.
        try await Task.sleep(nanoseconds: UInt64(Self.compilationGrace * 1_000_000_000))
        let lateWebView = try makeTabWebView()
        let lateAllowedArrived = try await runPhase("late", in: lateWebView)
        let lateStaticBlocked = !server.received("/late/blocked-static.js")
        let lateDynamicBlocked = !server.received("/late/blocked-dynamic.js")
        let lateBareBlocked = !server.received("/late/blocked-nodot.js")

        // ---- Phase 4: positive control. Our own rule list, WebKit's own enforcement path.
        let controlList = try await compileControlRuleList()
        let controlWebView = try makeTabWebView()
        controlWebView.configuration.userContentController.add(controlList)
        let controlAllowedArrived = try await runPhase("control", in: controlWebView)
        let controlBareBlocked = !server.received("/control/blocked-control.js")
        let controlDottedBlocked = !server.received("/control/blocked-ctldot.js")

        // Printed whether the test passes or fails: this is the measurement DECISIONS §4.2 asks
        // for and it has to survive in the CI log either way.
        print("KIWIX_DNR_ENFORCEMENT "
            + "earlyStatic=\(earlyStaticBlocked ? "blocked" : "reached") "
            + "earlyDynamic=\(earlyDynamicBlocked ? "blocked" : "reached") "
            + "lateStatic=\(lateStaticBlocked ? "blocked" : "reached") "
            + "lateDynamic=\(lateDynamicBlocked ? "blocked" : "reached") "
            + "earlyBare=\(earlyBareBlocked ? "blocked" : "reached") "
            + "lateBare=\(lateBareBlocked ? "blocked" : "reached") "
            + "controlBare=\(controlBareBlocked ? "blocked" : "reached") "
            + "controlDotted=\(controlDottedBlocked ? "blocked" : "reached") "
            + "webRequestObserved=\(observedByWebRequest.count)")
        print("KIWIX_DNR_MATCHED \(matchedSignal.map { "\($0)" } ?? "no signal")")
        print("KIWIX_DNR_PATHS \(server.requestedPaths.joined(separator: " "))")
        print("KIWIX_WEBREQUEST_URLS \(observedByWebRequest.prefix(20).joined(separator: " "))")

        // ---- Apparatus first. If these fail, nothing above is interpretable.
        XCTAssertTrue(earlyAllowedArrived, "early: allowed.js never arrived. \(server.requestedPaths)")
        XCTAssertTrue(lateAllowedArrived, "late: allowed.js never arrived. \(server.requestedPaths)")
        XCTAssertTrue(controlAllowedArrived, "control: allowed.js never arrived. \(server.requestedPaths)")
        XCTAssertTrue(
            controlBareBlocked,
            "The positive control did not block. A WKContentRuleList compiled by this test, "
                + "attached to a web view from the shipping factory, failed to suppress "
                + "/control/blocked-control.js. Until this passes, no statement about "
                + "declarativeNetRequest can be made from this test — the apparatus itself is "
                + "not measuring anything. Observed: \(server.requestedPaths)"
        )
        XCTAssertTrue(
            controlDottedBlocked,
            "A filter containing a dot did not block through WKContentRuleListStore either, so "
                + "the dot — not the extension runtime — could explain the DNR result, and the "
                + "measurement below must not be read as a WebKit defect. "
                + "Observed: \(server.requestedPaths)"
        )

        // ---- The measurement.
        XCTAssertTrue(
            lateStaticBlocked,
            "A static declarativeNetRequest block rule did not stop the request \(Int(Self.compilationGrace))s "
                + "after the extension reported its ruleset enabled, while a hand-compiled rule list "
                + "on the same server did block. Observed: \(server.requestedPaths)"
        )
        XCTAssertTrue(
            lateBareBlocked,
            "A static declarativeNetRequest rule whose urlFilter is form-identical to the control "
                + "that did block (\"blocked-nodot\", no dot) still did not stop the request. "
                + "Observed: \(server.requestedPaths)"
        )
        XCTAssertTrue(
            lateDynamicBlocked,
            "A dynamic declarativeNetRequest block rule did not stop the request \(Int(Self.compilationGrace))s "
                + "after getDynamicRules() reported it installed, while a hand-compiled rule list "
                + "on the same server did block. Observed: \(server.requestedPaths)"
        )
    }
}
