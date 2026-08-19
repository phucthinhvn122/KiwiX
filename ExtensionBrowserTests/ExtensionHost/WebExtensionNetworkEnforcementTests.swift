import UIKit
import WebKit
import XCTest
@testable import ExtensionBrowser

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
/// DECISIONS §4.2.5 explicitly refuses to count as a pass. Three things make the difference here:
///
///   * A project-controlled server on `127.0.0.1`. Loopback needs no DNS, so a request that never
///     arrives was suppressed; it cannot be a name that failed to resolve. That confound is why
///     the M2 fixture (`blocked.kiwix.test`) could not be used as evidence.
///   * A baseline phase with **no extension loaded**, proving the same subresource is fetched
///     normally. Without it, absence proves nothing.
///   * Ordering. The two blocked scripts appear before the allowed one in the page, so the arrival
///     of the allowed sibling proves the earlier two had already been offered to the network stack.
@MainActor
final class WebExtensionNetworkEnforcementTests: XCTestCase {
    private var temporaryRoot: URL!
    private var host: WebExtensionHost!
    private var tabManager: TabManager!
    private var server: LocalHTTPServer!
    private var port: UInt16 = 0
    private var window: UIWindow!
    private var waiters: [NavigationSettledWaiter] = []

    /// Blocked first, allowed last. The order is the argument, not a detail.
    private static let subresources = ["blocked-static.js", "blocked-dynamic.js", "allowed.js"]
    private static let phases = ["baseline", "enforced"]

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

        // Off-screen but real: a web view with no window has bitten this project before, and the
        // shipping app never runs one detached.
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

    /// Bounded chance for a path to arrive before a negative assertion may conclude it never will.
    private func waitForRequest(_ path: String, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if server.received(path) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return server.received(path)
    }

    // MARK: - Tests

    func testDeclarativeNetRequestSuppressesARealRequest() async throws {
        let probeURL = try fixtureURL(named: "NetworkProbe")

        // ---- Phase 1: baseline. No extension is loaded, so every subresource must arrive.
        let baselineWebView = try makeTabWebView()
        try await load("/baseline.html", in: baselineWebView)
        _ = await waitForRequest("/baseline/allowed.js")

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
        var observedByWebRequest: [String] = []
        host.harnessChannel.onHandshake = { payload in
            switch payload["phase"] as? String {
            case "ready":
                readySignal = payload
                if readyGate.claim() { ready.fulfill() }
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

        // ---- Phase 2: the same page, a fresh tab, the extension now live.
        let enforcedWebView = try makeTabWebView()
        try await load("/enforced.html", in: enforcedWebView)

        XCTAssertTrue(
            server.received("/enforced.html"),
            "The page itself never reached the server; nothing below can be interpreted."
        )
        // Hoisted out of the assertion: XCTAssert* takes an autoclosure, which cannot be async.
        let allowedArrived = await waitForRequest("/enforced/allowed.js")
        XCTAssertTrue(
            allowedArrived,
            "The allowed subresource never arrived, so the page did not get far enough for the "
                + "negative assertions to mean anything. Observed: \(server.requestedPaths)"
        )

        let staticBlocked = !server.received("/enforced/blocked-static.js")
        let dynamicBlocked = !server.received("/enforced/blocked-dynamic.js")

        // Printed whether it passes or fails: this line is the measurement DECISIONS §4.2 asks for
        // and it has to survive in the CI log either way.
        print("KIWIX_DNR_ENFORCEMENT static=\(staticBlocked ? "blocked" : "reached") "
            + "dynamic=\(dynamicBlocked ? "blocked" : "reached") "
            + "webRequestObserved=\(observedByWebRequest.count)")
        print("KIWIX_DNR_PATHS \(server.requestedPaths.joined(separator: " "))")
        print("KIWIX_WEBREQUEST_URLS \(observedByWebRequest.prefix(20).joined(separator: " "))")

        XCTAssertTrue(
            staticBlocked,
            "A static declarativeNetRequest block rule did not stop the request: the server still "
                + "logged /enforced/blocked-static.js. Observed: \(server.requestedPaths)"
        )
        XCTAssertTrue(
            dynamicBlocked,
            "A dynamic declarativeNetRequest block rule did not stop the request: the server still "
                + "logged /enforced/blocked-dynamic.js. Observed: \(server.requestedPaths)"
        )
    }
}
