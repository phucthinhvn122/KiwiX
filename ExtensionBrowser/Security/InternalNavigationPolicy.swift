import Foundation

/// Which schemes the browser will render itself, as opposed to handing to another app.
///
/// The companion to `ExternalNavigationPolicy`: that one decides whether to leave KiwiX, this one
/// decides whether a scheme KiwiX *can* display should be displayed in the frame that asked.
enum InternalNavigationPolicy {
    /// Schemes a web view is allowed to load rather than being offered to another app.
    static let supportedSchemes: Set<String> = ["http", "https", "about", "file", "data", "blob"]

    static func isInternallySupported(scheme: String) -> Bool {
        supportedSchemes.contains(scheme.lowercased())
    }

    /// Whether a top-level navigation to this scheme has to be refused.
    ///
    /// `data:` only. Chrome and Safari both stopped honouring top-level `data:` navigations, and the
    /// reason is the address bar: a `data:` document has no host to show, so the omnibox cannot tell
    /// the user whose page they are looking at while the document renders an arbitrary copy of one.
    /// Redirect chains ending in `data:` were the delivery mechanism, which is why this is judged on
    /// the frame rather than on whether a person clicked.
    ///
    /// Three things are deliberately still allowed:
    /// - subframes, where the parent document's origin is what the address bar reports anyway;
    /// - downloads, because `<a download href="data:…">` is how a page hands over a file it built
    ///   client-side, and that never renders as a document;
    /// - every other scheme in `supportedSchemes`, none of which hide their origin this way.
    ///
    /// - Parameter isTopLevel: pass `true` when `targetFrame` is nil — a navigation with no target
    ///   frame yet is opening a new one, which is top level by the time it draws.
    static func blocksTopLevelNavigation(
        scheme: String,
        isTopLevel: Bool,
        isDownload: Bool
    ) -> Bool {
        guard !isDownload, isTopLevel else { return false }
        return scheme.lowercased() == "data"
    }
}
