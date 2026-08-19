import UIKit
import WebKit

@MainActor
final class WebViewConfigurationProvider {
    private let normalProcessPool = WKProcessPool()
    private var privateProcessPool = WKProcessPool()
    private let normalDataStore = WKWebsiteDataStore.default()
    private var privateDataStore = WKWebsiteDataStore.nonPersistent()
    private let extensionBridge: BrowserExtensionBridge

    /// Assigned after construction: the host needs a `TabManager`, which needs the factory that
    /// owns this provider, so the cycle has to be closed by the scene rather than by an init.
    weak var webExtensionHost: WebExtensionHost?

    init(extensionBridge: BrowserExtensionBridge? = nil) {
        self.extensionBridge = extensionBridge ?? .shared
    }

    func configuration(tabID: UUID, isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = isPrivate ? privateProcessPool : normalProcessPool
        configuration.websiteDataStore = isPrivate ? privateDataStore : normalDataStore
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio, .video]

        let contentController = WKUserContentController()
        configuration.userContentController = contentController

        if !isPrivate {
            // Spec §7: extensions are off in private browsing, so the controller is attached to
            // normal tabs only. `WKWebViewConfiguration` is copied when the web view is created,
            // which is why this cannot be set later.
            configuration.webExtensionController = webExtensionHost?.controller

            extensionBridge.integration?.configure(
                userContentController: contentController,
                context: BrowserExtensionTabContext(tabID: tabID, isPrivate: false)
            )
        }

        return configuration
    }

    func resetPrivateProfile() {
        privateProcessPool = WKProcessPool()
        privateDataStore = WKWebsiteDataStore.nonPersistent()
    }
}

@MainActor
final class WebViewFactory {
    private let configurationProvider: WebViewConfigurationProvider

    init(configurationProvider: WebViewConfigurationProvider? = nil) {
        self.configurationProvider = configurationProvider ?? WebViewConfigurationProvider()
    }

    func makeWebView(tabID: UUID, isPrivate: Bool) -> WKWebView {
        let webView = WKWebView(
            frame: .zero,
            configuration: configurationProvider.configuration(tabID: tabID, isPrivate: isPrivate)
        )
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        #if DEBUG
        webView.isInspectable = true
        #endif

        return webView
    }

    func resetPrivateProfile() {
        configurationProvider.resetPrivateProfile()
    }
}
