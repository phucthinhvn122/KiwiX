import UIKit
import WebKit

/// The single browser window exposed to extensions.
///
/// v1 is one scene, one window (ADR-004). Private tabs are never listed: spec §7 keeps extensions
/// off in private browsing, so from an extension's point of view those tabs do not exist.
@MainActor
final class WebExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private weak var host: WebExtensionHost?

    init(host: WebExtensionHost) {
        self.host = host
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        host?.visibleTabAdapters() ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        host?.activeTabAdapter()
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        // An iPhone browser window always fills the screen; there is no restore geometry.
        .fullscreen
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        screenBounds
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        screenBounds
    }

    func focus(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // Already the only window.
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(WebExtensionHostError.additionalWindowsUnsupported)
    }

    private var screenBounds: CGRect {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
    }
}
