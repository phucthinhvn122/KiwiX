import Foundation

/// Which observable properties of a tab changed.
///
/// Deliberately WebKit-free so `TabManager` stays independent of `WKWebExtension`; the host maps
/// these onto `WKWebExtension.TabChangedProperties`.
struct TabObservedChange: OptionSet, Sendable {
    let rawValue: Int

    static let title = TabObservedChange(rawValue: 1 << 0)
    static let url = TabObservedChange(rawValue: 1 << 1)
    static let loading = TabObservedChange(rawValue: 1 << 2)
    static let size = TabObservedChange(rawValue: 1 << 3)
}

/// Outbound port from `TabManager` to the WebExtension host.
///
/// `WKWebExtensionController` has no way to observe the browser; the app must tell it when tabs
/// open, close, activate, move or change. ADR-004 fixes the ordering contract: a tab is announced
/// as open before it can be activated, and announced as closed only after it has left the window.
@MainActor
protocol TabWebExtensionObserving: AnyObject {
    func tabManager(_ manager: TabManager, didOpenTab tab: Tab)
    func tabManager(_ manager: TabManager, didCloseTabWithID tabID: UUID, isPrivate: Bool)
    func tabManager(_ manager: TabManager, didActivateTab tab: Tab, previousTabID: UUID?)
    func tabManager(_ manager: TabManager, didMoveTab tab: Tab, fromIndex index: Int)
    func tabManager(_ manager: TabManager, didChange change: TabObservedChange, for tab: Tab)
}
