import UIKit

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private weak var browserViewController: BrowserViewController?
    private var extensionIntegration: ExtensionBrowserIntegration?
    private var extensionManagerCoordinator: ExtensionManagerPresentationCoordinator?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let extensionIntegration = ExtensionBrowserIntegration()
        extensionIntegration.activate()
        self.extensionIntegration = extensionIntegration

        let configurationProvider = WebViewConfigurationProvider(extensionBridge: .shared)
        let webViewFactory = WebViewFactory(configurationProvider: configurationProvider)
        let tabManager = TabManager(webViewFactory: webViewFactory)
        let browser = BrowserViewController(
            tabManager: tabManager,
            settingsStore: .shared,
            extensionBridge: .shared
        )
        extensionManagerCoordinator = ExtensionManagerPresentationCoordinator(
            presentingViewController: browser,
            integration: extensionIntegration
        )

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = .systemBlue
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
    }
}
