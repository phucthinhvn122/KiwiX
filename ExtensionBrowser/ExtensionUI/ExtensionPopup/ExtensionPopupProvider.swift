import UIKit
import WebKit

@MainActor
public protocol ExtensionPopupProviding: AnyObject {
    func makePopupViewController(
        for extensionID: ExtensionIdentifier,
        tabID: UUID
    ) async throws -> UIViewController
}

@MainActor
public final class DefaultExtensionPopupProvider: ExtensionPopupProviding {
    private static var cachedRemoteResourceBlocklist: WKContentRuleList?
    private let repository: ExtensionRepository
    private let registry: ExtensionAPIRegistry

    public init(repository: ExtensionRepository, registry: ExtensionAPIRegistry) {
        self.repository = repository
        self.registry = registry
    }

    public func makePopupViewController(
        for extensionID: ExtensionIdentifier,
        tabID: UUID
    ) async throws -> UIViewController {
        guard let installed = try await repository.extensionWithID(extensionID), installed.metadata.isEnabled else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        guard let popupPath = installed.manifest.action?.defaultPopup, !popupPath.isEmpty else {
            throw ExtensionRuntimeError.unavailable("extension does not define action.default_popup")
        }
        let popupURL = try ExtensionResourcePath.containedURL(for: popupPath, under: installed.filesURL)
        guard (try? popupURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ExtensionRuntimeError.resourceNotFound(popupPath)
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(try await Self.remoteResourceBlocklist())
        configuration.userContentController = controller
        let name = "extensionPopupBridge_\(extensionID.rawValue)"
        let handler = ExtensionScriptMessageHandler(extensionID: extensionID, tabID: tabID, registry: registry)
        controller.addScriptMessageHandler(handler, contentWorld: .page, name: name)
        controller.addUserScript(WKUserScript(
            source: ChromeBridgeJavaScript.source(messageHandlerName: name, extensionID: extensionID),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        let popup = ExtensionPopupViewController(configuration: configuration, allowedRootURL: installed.filesURL)
        popup.load(fileURL: popupURL, allowingReadAccessTo: installed.filesURL)
        return popup
    }

    private static func remoteResourceBlocklist() async throws -> WKContentRuleList {
        if let cachedRemoteResourceBlocklist { return cachedRemoteResourceBlocklist }
        let source = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        let ruleList = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WKContentRuleList, Error>) in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ExtensionBrowser.Popup.LocalResourcesOnly.v1",
                encodedContentRuleList: source
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: error ?? ExtensionRuntimeError.unavailable(
                        "could not create popup resource policy"
                    ))
                }
            }
        }
        cachedRemoteResourceBlocklist = ruleList
        return ruleList
    }
}

@MainActor
private final class ExtensionPopupViewController: UIViewController {
    private let webView: WKWebView
    private let allowedRootURL: URL

    init(configuration: WKWebViewConfiguration, allowedRootURL: URL) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.allowedRootURL = allowedRootURL.standardizedFileURL
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 360, height: 480)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func load(fileURL: URL, allowingReadAccessTo rootURL: URL) {
        loadViewIfNeeded()
        webView.loadFileURL(fileURL, allowingReadAccessTo: rootURL)
    }
}

extension ExtensionPopupViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, url.isFileURL else {
            decisionHandler(.cancel)
            return
        }
        let candidate = url.standardizedFileURL.path
        let rootPath = allowedRootURL.path.hasSuffix("/") ? allowedRootURL.path : allowedRootURL.path + "/"
        decisionHandler(candidate.hasPrefix(rootPath) ? .allow : .cancel)
    }
}
