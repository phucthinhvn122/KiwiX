import UIKit
import WebKit

@MainActor
final class WebViewConfigurationProvider {
    private let normalProcessPool = WKProcessPool()
    private let privateProcessPool = WKProcessPool()
    private let normalDataStore = WKWebsiteDataStore.default()
    private let privateDataStore = WKWebsiteDataStore.nonPersistent()
    private let extensionBridge: BrowserExtensionBridge

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
            extensionBridge.integration?.configure(
                userContentController: contentController,
                context: BrowserExtensionTabContext(tabID: tabID, isPrivate: false)
            )
        }

        return configuration
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
}
