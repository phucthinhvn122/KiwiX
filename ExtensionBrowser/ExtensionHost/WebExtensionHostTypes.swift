import Foundation
import WebKit

/// How an extension's permissions are resolved by ``WebExtensionHost``.
///
/// Spec §7 requires an explicit permission sheet before install, with a bold warning for
/// `<all_urls>`. That UI is M3 work. Until it exists the host only auto-grants for bundles the
/// app itself ships (the API harness) and denies every runtime prompt for anything else, so no
/// third-party extension can silently acquire host access.
enum WebExtensionPermissionPolicy: Sendable, Equatable {
    /// Nothing is granted and every runtime prompt resolves to an empty set.
    case denyAll
    /// Grant everything the manifest requests at load time. First-party bundles only.
    case trustFirstPartyBundle
}

enum WebExtensionHostError: LocalizedError, Equatable {
    case actionPopupUnsupported
    case optionsPageUnsupported
    case additionalWindowsUnsupported
    case nativeMessagingUnavailable
    case messagePortUnsupported
    case tabCreationFailed(String)

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
        case .messagePortUnsupported:
            return "Native message ports are not available in this build yet."
        case .tabCreationFailed(let reason):
            return reason
        }
    }
}

/// The pass/fail table produced by the bundled API harness extension.
///
/// The shape is defined by the harness JavaScript; Swift only decodes and renders it. Spec §2.4
/// says the API matrix must come from a real run, so nothing here is hard-coded.
struct WebExtensionProbeReport: Codable, Sendable, Equatable {
    struct Probe: Codable, Sendable, Equatable {
        enum Status: String, Codable, Sendable {
            case pass
            case fail
            case unsupported
            case skipped
        }

        let id: String
        let area: String
        let status: Status
        let detail: String?
    }

    let schema: Int
    let environment: [String: String]
    let probes: [Probe]
    /// Filled in by the host, not the extension: which transport delivered the report.
    var channel: String?

    var passCount: Int { probes.filter { $0.status == .pass }.count }
    var failCount: Int { probes.filter { $0.status == .fail }.count }
    var unsupportedCount: Int { probes.filter { $0.status == .unsupported }.count }
    var skippedCount: Int { probes.filter { $0.status == .skipped }.count }

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
        lines.append("  total \(probes.count)  pass \(passCount)  fail \(failCount)  unsupported \(unsupportedCount)  skipped \(skippedCount)")
        return lines.joined(separator: "\n")
    }
}
