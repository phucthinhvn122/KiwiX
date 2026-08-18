import Foundation

struct WebDialogContent: Equatable {
    let title: String
    let message: String
    let defaultText: String?
}

enum WebDialogPolicy {
    static let maximumMessageByteCount = 2_048
    static let maximumDefaultTextByteCount = 512

    static func content(pageURL: URL?, message: String, defaultText: String? = nil) -> WebDialogContent {
        let origin: String
        if let pageURL,
           let scheme = pageURL.scheme?.lowercased(),
           let host = pageURL.host(percentEncoded: true),
           !host.isEmpty {
            let port = pageURL.port.map { ":\($0)" } ?? ""
            origin = "\(scheme)://\(host.lowercased())\(port)"
        } else {
            origin = "This page"
        }
        return WebDialogContent(
            title: "\(origin) says:",
            message: SafeInput.displayText(
                message,
                maximumByteCount: maximumMessageByteCount,
                allowsNewlines: true
            ),
            defaultText: defaultText.map {
                SafeInput.displayText($0, maximumByteCount: maximumDefaultTextByteCount)
            }
        )
    }
}

@MainActor
final class WebDialogRateLimiter {
    private var presentations: [UUID: [Date]] = [:]
    private let maximumDialogs: Int
    private let window: TimeInterval

    init(maximumDialogs: Int = 3, window: TimeInterval = 30) {
        self.maximumDialogs = maximumDialogs
        self.window = window
    }

    func consume(tabID: UUID, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var recent = presentations[tabID, default: []].filter { $0 > cutoff }
        guard recent.count < maximumDialogs else {
            presentations[tabID] = recent
            return false
        }
        recent.append(now)
        presentations[tabID] = recent
        return true
    }

    func remove(tabID: UUID) {
        presentations.removeValue(forKey: tabID)
    }
}
