import SwiftUI
import UIKit

@MainActor
final class ExtensionManagerPresentationCoordinator {
    private weak var presentingViewController: UIViewController?
    private let integration: ExtensionBrowserIntegration
    private var observer: NSObjectProtocol?

    init(presentingViewController: UIViewController, integration: ExtensionBrowserIntegration) {
        self.presentingViewController = presentingViewController
        self.integration = integration
        observer = NotificationCenter.default.addObserver(
            forName: BrowserExtensionNotifications.requestPresentManager,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.presentManager() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func presentManager() {
        guard let presenter = topViewController(from: presentingViewController),
              presenter.presentedViewController == nil else { return }
        let view = ExtensionManagerView(
            repository: integration.repository,
            installer: integration.installer
        )
        let hosting = UIHostingController(rootView: view)
        hosting.modalPresentationStyle = .formSheet
        presenter.present(hosting, animated: true)
    }

    private func topViewController(from root: UIViewController?) -> UIViewController? {
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }
}
