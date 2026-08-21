import Foundation

/// A WebKit decision/completion handler that is answered exactly once, including when it is dropped.
///
/// WebKit does not tolerate an unanswered handler. `WKWebView` keeps a guard object alive for the
/// duration of `decidePolicyFor…` / `runJavaScriptAlertPanel…` and raises an uncatchable
/// `NSInternalInconsistencyException` from *its* deallocation if nobody called back — the app dies
/// with "Completion handler passed to … was not called", and the backtrace points at WebKit rather
/// than at whatever dropped it.
///
/// The browser answers three of those handlers from a `UIAlertController`, which is not a promise
/// that either action runs. `BrowserViewController.presentExtensions(importing:)` calls
/// `dismiss(animated: false)` to clear whatever is on screen when another app hands KiwiX a package,
/// and an alert dismissed that way releases both of its action closures without invoking either.
///
/// So the answer is tied to the object's lifetime rather than to a button: whoever gets there first
/// wins, and if nothing does, `deinit` supplies the conservative default. The fallback is the value
/// that denies — `.cancel`, `false`, `nil` — because the case being handled is "the question was
/// never put to the user", and web content must not be granted something on a dismissal.
///
/// Not `Sendable`, and deliberately so: every use is on the main actor. The one place that cannot be
/// asserted is `deinit`, which runs wherever the last reference is released, so it hops if it has to.
final class WebKitDecisionOnce<Value> {
    private var handler: ((Value) -> Void)?
    private let fallback: Value

    /// - Parameter fallback: the answer given if this object is released before `callAsFunction`.
    init(fallback: Value, handler: @escaping (Value) -> Void) {
        self.fallback = fallback
        self.handler = handler
    }

    /// Spelled as a call so a wrapped handler reads the same as the raw one: `decide(.cancel)`.
    func callAsFunction(_ value: Value) {
        take()?(value)
    }

    deinit {
        guard let handler = take() else { return }
        let fallback = self.fallback
        if Thread.isMainThread {
            handler(fallback)
        } else {
            DispatchQueue.main.async { handler(fallback) }
        }
    }

    private func take() -> ((Value) -> Void)? {
        let current = handler
        handler = nil
        return current
    }
}
