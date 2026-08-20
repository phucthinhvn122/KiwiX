import Foundation
import WebKit

/// How an extension's permissions are resolved by ``WebExtensionHost``.
///
/// Spec §7 requires an explicit permission sheet before install, with a bold warning for
/// `<all_urls>`. `userGranted` is what that sheet produces: the exact set the user ticked, carried
/// across launches by the installed-extension catalog. Nothing widens it afterwards.
enum WebExtensionPermissionPolicy: Sendable, Equatable {
    /// Nothing is granted. Every requested permission is denied explicitly rather than left unset,
    /// so a later default change cannot turn silence into consent.
    case denyAll
    /// Grant everything the manifest requests at load time. First-party bundles only — the app's
    /// own API harness, never a sideloaded package.
    case trustFirstPartyBundle
    /// Grant exactly what the user approved on the permission sheet.
    ///
    /// Stored as strings because these outlive the process: the catalog on disk is the record of
    /// what was agreed to, and `WKWebExtension.Permission` / `MatchPattern` are runtime types.
    case userGranted(permissions: Set<String>, matchPatterns: Set<String>)

    /// Whether a *runtime* prompt is answered with a grant without asking the user.
    ///
    /// Only first-party bundles are. Under `userGranted` the install-time decisions are already on
    /// the context, so anything the runtime still has to ask about is by definition something the
    /// user did not approve — and there is no mid-session sheet yet, so it is denied rather than
    /// guessed at. The exhaustive switch is deliberate: a new policy case must not be able to reach
    /// this code path by falling through to a default.
    var autoGrantsRuntimePrompts: Bool {
        switch self {
        case .trustFirstPartyBundle:
            return true
        case .denyAll, .userGranted:
            return false
        }
    }
}

enum WebExtensionHostError: LocalizedError, Equatable {
    case actionPopupUnsupported
    case optionsPageUnsupported
    case additionalWindowsUnsupported
    case nativeMessagingUnavailable
    case backgroundContentTimedOut(TimeInterval)
    case messagePortUnsupported
    case tabCreationFailed(String)
    case navigationBlocked(scheme: String)
    case tabCreationRateLimited(limit: Int, seconds: Int)

    var errorDescription: String? {
        switch self {
        case .actionPopupUnsupported:
            return "Extension popups are not available in this build yet."
        case .optionsPageUnsupported:
            return "Extension options pages are not available in this build yet."
        case .additionalWindowsUnsupported:
            return "This browser uses a single window."
        case .nativeMessagingUnavailable:
            return "No native application is registered for this message."
        case .backgroundContentTimedOut(let seconds):
            return "Background content did not start within \(Int(seconds))s."
        case .messagePortUnsupported:
            return "Native message ports are not available in this build yet."
        case .tabCreationFailed(let reason):
            return reason
        case .navigationBlocked(let scheme):
            return "Extensions cannot open \(scheme): URLs."
        case .tabCreationRateLimited(let limit, let seconds):
            return "This extension opened too many tabs (limit \(limit) per \(seconds)s)."
        }
    }
}

/// The pass/fail table produced by the bundled API harness extension.
///
/// The shape is defined by the harness JavaScript; Swift only decodes and renders it. Spec §2.4
/// says the API matrix must come from a real run, so nothing here is hard-coded.
struct WebExtensionProbeReport: Codable, Sendable, Equatable {
    struct Probe: Codable, Sendable, Equatable {
        /// The five outcomes DECISIONS §4.2 requires. `available` exists because the presence of
        /// a property is explicitly *not* evidence that an API works (§4.2.5), so a probe that
        /// only did feature detection must never be reported as a pass.
        enum Status: String, Codable, Sendable {
            case available
            case pass
            case fail
            case timeout
            case unsupported
            case skipped
        }

        let id: String
        let area: String
        let status: Status
        let detail: String?
    }

    let schema: Int
    /// The extension fills in what JavaScript can see; the host merges in OS version, device model
    /// and timestamp, which the extension cannot be trusted to report (§4.2.3).
    var environment: [String: String]
    let probes: [Probe]
    /// Filled in by the host, not the extension: which transport delivered the report.
    var channel: String?

    func count(of status: Probe.Status) -> Int {
        probes.filter { $0.status == status }.count
    }

    var passCount: Int { count(of: .pass) }
    var failCount: Int { count(of: .fail) }
    var timeoutCount: Int { count(of: .timeout) }
    var availableCount: Int { count(of: .available) }
    var unsupportedCount: Int { count(of: .unsupported) }
    var skippedCount: Int { count(of: .skipped) }

    /// Single grep-able line for CI logs, as required by DECISIONS §4.2.4.
    static let consoleMarker = "KIWIX_HARNESS_REPORT"

    func markerLine(jsonPath: String) -> String {
        "\(Self.consoleMarker) channel=\(channel ?? "unknown") total=\(probes.count) pass=\(passCount) fail=\(failCount) timeout=\(timeoutCount) available=\(availableCount) unsupported=\(unsupportedCount) skipped=\(skippedCount) json=\(jsonPath)"
    }

    /// Fixed-width console table. Printed by the harness test so CI logs carry the evidence.
    func consoleTable() -> String {
        let idWidth = max(24, probes.map(\.id.count).max() ?? 24)
        var lines: [String] = []
        lines.append("WebExtension API matrix — channel: \(channel ?? "unknown"), schema \(schema)")
        for key in environment.keys.sorted() {
            lines.append("  env \(key) = \(environment[key] ?? "")")
        }
        lines.append("")
        lines.append("  \("API".padding(toLength: idWidth, withPad: " ", startingAt: 0))  \("AREA".padding(toLength: 14, withPad: " ", startingAt: 0))  \("STATUS".padding(toLength: 11, withPad: " ", startingAt: 0))  DETAIL")
        lines.append("  \(String(repeating: "-", count: idWidth))  \(String(repeating: "-", count: 14))  \(String(repeating: "-", count: 11))  \(String(repeating: "-", count: 40))")
        for probe in probes {
            let id = probe.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let area = probe.area.padding(toLength: 14, withPad: " ", startingAt: 0)
            let status = probe.status.rawValue.uppercased().padding(toLength: 11, withPad: " ", startingAt: 0)
            let detail = (probe.detail ?? "").replacingOccurrences(of: "\n", with: " ")
            lines.append("  \(id)  \(area)  \(status)  \(detail)")
        }
        lines.append("")
        lines.append(
            "  total \(probes.count)  pass \(passCount)  fail \(failCount)  timeout \(timeoutCount)"
                + "  available \(availableCount)  unsupported \(unsupportedCount)  skipped \(skippedCount)"
        )
        return lines.joined(separator: "\n")
    }
}

/// One-shot gate so a continuation raced between a completion handler and a timeout is resumed
/// exactly once. Resuming twice is a hard crash, not a warning.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
