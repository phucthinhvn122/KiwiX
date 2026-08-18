import WebKit

/// Owns user-script composition for a controller. Feature code replaces only its own scripts;
/// rebuilding never loses browser or security scripts installed by another subsystem.
@MainActor
final class WebViewUserScriptRegistry {
    enum Owner: Hashable {
        case browser
        case security
        case extensionRuntime(String)
    }

    private weak var controller: WKUserContentController?
    private var scriptsByOwner: [Owner: [WKUserScript]]

    init(controller: WKUserContentController) {
        self.controller = controller
        scriptsByOwner = controller.userScripts.isEmpty ? [:] : [.browser: controller.userScripts]
    }

    func replace(_ scripts: [WKUserScript], ownedBy owner: Owner) {
        scriptsByOwner[owner] = scripts
        rebuild()
    }

    func replaceExtensionScripts(_ groups: [String: [WKUserScript]]) {
        scriptsByOwner = scriptsByOwner.filter {
            if case .extensionRuntime = $0.key { return false }
            return true
        }
        for (extensionID, scripts) in groups {
            scriptsByOwner[.extensionRuntime(extensionID)] = scripts
        }
        rebuild()
    }

    private func rebuild() {
        guard let controller else { return }
        controller.removeAllUserScripts()
        for owner in scriptsByOwner.keys.sorted(by: { sortKey($0) < sortKey($1) }) {
            scriptsByOwner[owner]?.forEach(controller.addUserScript)
        }
    }

    private func sortKey(_ owner: Owner) -> String {
        switch owner {
        case .browser: return "0-browser"
        case .security: return "1-security"
        case .extensionRuntime(let identifier): return "2-extension-\(identifier)"
        }
    }
}
