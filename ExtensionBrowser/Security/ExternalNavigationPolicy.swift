import Foundation

enum ExternalNavigationDecision: Equatable {
    case block
    case open
    case confirm(displayName: String)
}

enum ExternalNavigationPolicy {
    static let maximumURLByteCount = 4_096

    private static let allowedSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "maps", "itms-apps"
    ]
    private static let neverExternalSchemes: Set<String> = [
        "http", "https", "about", "file", "data", "blob", "javascript"
    ]

    static func decision(
        for url: URL,
        isUserActivated: Bool,
        isTopLevel: Bool,
        isActiveTab: Bool,
        isApplicationActive: Bool
    ) -> ExternalNavigationDecision {
        guard isUserActivated, isTopLevel, isActiveTab, isApplicationActive,
              url.absoluteString.utf8.count <= maximumURLByteCount,
              url.user == nil,
              url.password == nil,
              let scheme = url.scheme?.lowercased(),
              isValidScheme(scheme),
              !neverExternalSchemes.contains(scheme) else {
            return .block
        }
        if allowedSchemes.contains(scheme) { return .open }

        let host = url.host == nil ? nil : SafeInput.displayHost(for: url, fallback: "")
        let displayName = host.flatMap { $0.isEmpty ? nil : "\(scheme) link for \($0)" } ?? "\(scheme) link"
        return .confirm(displayName: SafeInput.displayText(
            displayName,
            maximumByteCount: 160,
            allowsNewlines: false
        ))
    }

    private static func isValidScheme(_ scheme: String) -> Bool {
        guard (1...32).contains(scheme.utf8.count),
              let first = scheme.utf8.first,
              (65...90).contains(first) || (97...122).contains(first) else {
            return false
        }
        return scheme.utf8.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                $0 == 43 || $0 == 45 || $0 == 46
        }
    }
}

@MainActor
final class ExternalNavigationRateLimiter {
    private var attempts: [UUID: [Date]] = [:]
    private let maximumAttempts: Int
    private let window: TimeInterval

    init(maximumAttempts: Int = 2, window: TimeInterval = 10) {
        self.maximumAttempts = maximumAttempts
        self.window = window
    }

    func consume(tabID: UUID, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var recent = attempts[tabID, default: []].filter { $0 > cutoff }
        guard recent.count < maximumAttempts else {
            attempts[tabID] = recent
            return false
        }
        recent.append(now)
        attempts[tabID] = recent
        return true
    }

    func remove(tabID: UUID) {
        attempts.removeValue(forKey: tabID)
    }
}

@MainActor
final class PopupCreationRateLimiter {
    private var attempts: [UUID: [Date]] = [:]
    private let maximumAttempts: Int
    private let window: TimeInterval

    init(maximumAttempts: Int = 3, window: TimeInterval = 10) {
        self.maximumAttempts = maximumAttempts
        self.window = window
    }

    func consume(tabID: UUID, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var recent = attempts[tabID, default: []].filter { $0 > cutoff }
        guard recent.count < maximumAttempts else {
            attempts[tabID] = recent
            return false
        }
        recent.append(now)
        attempts[tabID] = recent
        return true
    }

    func remove(tabID: UUID) { attempts.removeValue(forKey: tabID) }
}
