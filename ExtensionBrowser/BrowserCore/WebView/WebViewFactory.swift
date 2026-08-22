import UIKit
import WebKit

@MainActor
final class WebViewConfigurationProvider {
    private let normalProcessPool = WKProcessPool()
    private var privateProcessPool = WKProcessPool()
    private let normalDataStore = WKWebsiteDataStore.default()
    private var privateDataStore = WKWebsiteDataStore.nonPersistent()

    /// Assigned after construction: the host needs a `TabManager`, which needs the factory that
    /// owns this provider, so the cycle has to be closed by the scene rather than by an init.
    weak var webExtensionHost: WebExtensionHost?

    func configuration(isPrivate: Bool) -> WKWebViewConfiguration {
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

    func makeWebView(isPrivate: Bool) -> WKWebView {
        let webView = WKWebView(
            frame: .zero,
            configuration: configurationProvider.configuration(isPrivate: isPrivate)
        )
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.keyboardDismissMode = .interactive
        // `.always`, not `.never`. The web view now reaches the top of the window, so the page
        // paints behind the status bar and the notch the way it does in Safari; the scroll view is
        // what keeps the *content* out from under them. With `.never` the choice was between text
        // under the clock and a dead strip above the page, and the strip is what shipped.
        //
        // No double inset in landscape: `webContentContainer` is still pinned to the horizontal safe
        // area, so the web view sits entirely inside it and its own horizontal safe-area inset is
        // zero. Only the top has anything left to inset.
        webView.scrollView.contentInsetAdjustmentBehavior = .always

        #if DEBUG
        webView.isInspectable = true
        #endif

        return webView
    }

    func resetPrivateProfile() {
        configurationProvider.resetPrivateProfile()
    }
}
