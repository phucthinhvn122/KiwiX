import Foundation
import UIKit
import WebKit

enum TabLifecycleState: String, Codable, Sendable {
    case active = "ACTIVE"
    case warm = "WARM"
    case suspended = "SUSPENDED"
}

struct TabRecord: Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var url: URL?
    var faviconURL: URL?
    var snapshotFileName: String?
    var lastAccessDate: Date
    var isPrivate: Bool
    var state: TabLifecycleState
}

@MainActor
final class Tab: Identifiable {
    let id: UUID
    var title: String
    var url: URL?
    var faviconURL: URL?
    var snapshotFileName: String?
    var lastAccessDate: Date
    let isPrivate: Bool
    var state: TabLifecycleState

    var webView: WKWebView?
    var snapshot: UIImage?
    /// Decoded UI image is intentionally transient; only `faviconURL` is persisted.
    var favicon: UIImage?
    var needsInitialNavigation: Bool
    var isRestoringFromSuspension = false

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        url: URL? = nil,
        faviconURL: URL? = nil,
        snapshotFileName: String? = nil,
        lastAccessDate: Date = Date(),
        isPrivate: Bool = false,
        state: TabLifecycleState = .suspended,
        webView: WKWebView? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.faviconURL = faviconURL
        self.snapshotFileName = snapshotFileName
        self.lastAccessDate = lastAccessDate
        self.isPrivate = isPrivate
        self.state = state
        self.webView = webView
        needsInitialNavigation = url != nil && url?.absoluteString != "about:blank"
    }

    convenience init(record: TabRecord) {
        self.init(
            id: record.id,
            title: record.title,
            url: record.url,
            faviconURL: record.faviconURL,
            snapshotFileName: record.snapshotFileName,
            lastAccessDate: record.lastAccessDate,
            isPrivate: record.isPrivate,
            state: .suspended
        )
    }

    var record: TabRecord {
        TabRecord(
            id: id,
            title: title,
            url: url,
            faviconURL: faviconURL,
            snapshotFileName: snapshotFileName,
            lastAccessDate: lastAccessDate,
            isPrivate: isPrivate,
            state: state
        )
    }

    func updateFaviconCandidate() {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host else {
            faviconURL = nil
            return
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/favicon.ico"
        faviconURL = components.url
    }
}
