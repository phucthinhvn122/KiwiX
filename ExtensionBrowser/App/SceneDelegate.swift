import UIKit

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private weak var browserViewController: BrowserViewController?
    private var webExtensionHost: WebExtensionHost?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        KiwiTheme.applyGlobalAppearance()

        let configurationProvider = WebViewConfigurationProvider()
        let webViewFactory = WebViewFactory(configurationProvider: configurationProvider)
        let tabManager = TabManager(webViewFactory: webViewFactory)

        // Path A runtime (ADR-001). Wired before the browser is built so the window and its tabs
        // are announced ahead of the asynchronous session restore.
        let webExtensionHost = WebExtensionHost()
        webExtensionHost.attach(tabManager: tabManager)
        configurationProvider.webExtensionHost = webExtensionHost
        webExtensionHost.startSession()
        self.webExtensionHost = webExtensionHost

        let browser = BrowserViewController(
            tabManager: tabManager,
            settingsStore: .shared
        )

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = KiwiTheme.accentDeep
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        browserViewController = browser
        PerformanceProfiler.event("App UI Ready")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        browserViewController?.prepareForBackground()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        browserViewController?.prepareForBackground()
        webExtensionHost?.endSession()
    }
}
