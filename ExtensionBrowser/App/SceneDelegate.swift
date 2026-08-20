import UIKit

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private weak var browserViewController: BrowserViewController?
    private var webExtensionHost: WebExtensionHost?
    private var extensionCoordinator: ExtensionInstallCoordinator?

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

        // Everything the user installed is reloaded from the catalog, not from whatever happened to
        // still be on disk. Deliberately not awaited: an extension that takes a moment to load must
        // not hold up first paint.
        let extensionCoordinator = ExtensionInstallCoordinator(host: webExtensionHost)
        self.extensionCoordinator = extensionCoordinator
        Task { await extensionCoordinator.restore() }

        let browser = BrowserViewController(
            tabManager: tabManager,
            settingsStore: .shared,
            extensionCoordinator: extensionCoordinator
        )

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = KiwiTheme.accentDeep
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        browserViewController = browser
        PerformanceProfiler.event("App UI Ready")

        openExtensionPackage(in: connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        openExtensionPackage(in: URLContexts)
    }

    /// A `.crx` or `.zip` handed over by another app.
    ///
    /// Only a copy is accepted. The app does not declare `LSSupportsOpeningDocumentsInPlace`, so
    /// every incoming document lands in our inbox — and the import path deletes what it reads,
    /// which must never be the user's own file somewhere else.
    private func openExtensionPackage(in contexts: Set<UIOpenURLContext>) {
        guard let context = contexts.first(where: { $0.url.isFileURL && !$0.options.openInPlace }) else { return }
        browserViewController?.presentExtensionInstall(fileURL: context.url)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        browserViewController?.prepareForBackground()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        browserViewController?.prepareForBackground()
        webExtensionHost?.endSession()
    }
}
