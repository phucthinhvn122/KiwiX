import Foundation

/// What an extension may ask the browser to open, and how often.
///
/// Both checks existed in the app-owned runtime that ADR-001 retired
/// (`ExtensionAPIRegistry.isAllowedTabURL` and `ExtensionTabCreationLimiter`) and neither moved to
/// WebKit with the rest of the runtime. `tabs.create`, `tabs.update` and `tabs.duplicate` all
/// re-enter this app through `WKWebExtensionControllerDelegate` and `WKWebExtensionTab`, so if the
/// app does not check them, nothing does.
enum WebExtensionTabPolicy {
    /// Extensions may only navigate a tab to a scheme a user could have typed.
    ///
    /// `TabManager.navigate` hands the URL straight to `WKWebView.load` with no scheme filter, and
    /// the app's own navigation gate deliberately permits `file`, `data` and `blob` for loads the
    /// user started. Reusing `SafePersistence.isSafePersistedURL` keeps the extension-facing rule
    /// identical to the one already applied to persisted tab state: http/https or exactly
    /// `about:blank`, no embedded credentials, bounded length.
    static func isAllowedNavigationURL(_ url: URL) -> Bool {
        SafePersistence.isSafePersistedURL(url)
    }
}

/// Sliding-window cap on how many tabs one extension may open.
///
/// `TabManager`'s 50-tab ceiling is a capacity limit, not a rate limit: closing a tab frees the
/// slot, so a create/close loop is unbounded. This bounds the rate instead, per extension context.
@MainActor
final class WebExtensionTabRateLimiter {
    let limit: Int
    let window: TimeInterval

    private var events: [ObjectIdentifier: [Date]] = [:]

    init(limit: Int = 10, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// - Parameter context: identity is by object, not by value — the caller passes the
    ///   `WKWebExtensionContext`. Typed as `AnyObject` so this stays testable without standing up a
    ///   real extension, and so the limiter carries no WebKit dependency of its own.
    /// - Returns: `true` when the caller may create a tab, recording it against the budget.
    func allow(context: AnyObject, now: Date = Date()) -> Bool {
        let key = ObjectIdentifier(context)
        let cutoff = now.addingTimeInterval(-window)
        var recent = (events[key] ?? []).filter { $0 > cutoff }
        guard recent.count < limit else {
            events[key] = recent
            return false
        }
        recent.append(now)
        events[key] = recent
        return true
    }

    func forget(context: AnyObject) {
        events.removeValue(forKey: ObjectIdentifier(context))
    }

    func forgetAll() {
        events.removeAll()
    }
}
