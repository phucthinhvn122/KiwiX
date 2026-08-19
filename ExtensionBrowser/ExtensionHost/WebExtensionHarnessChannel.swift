import Foundation

/// Receives the API harness report over whichever transport survives on the device.
///
/// Two transports are supported on purpose, because *whether they work at all* is part of what
/// M2 has to measure:
///   1. `runtime.sendNativeMessage` → `WKWebExtensionControllerDelegate`
///   2. a chunked `tabs.create` beacon to `harnessBeaconHost`, intercepted before a real tab is
///      created
///
/// The channel is inert unless a test explicitly enables it, so a third-party extension in a
/// shipping build can never drive it.
@MainActor
final class WebExtensionHarnessChannel {
    static let beaconHost = "kiwix-harness.invalid"
    static let nativeApplicationIdentifier = "com.phucthinhvn122.KiwiX.harness"

    private(set) var isEnabled = false
    private var chunks: [Int: String] = [:]
    private(set) var report: WebExtensionProbeReport?
    var onReport: ((WebExtensionProbeReport) -> Void)?
    /// Every handshake dictionary, verbatim. M3's enforcement probe uses handshakes as a general
    /// extension→host signal ("rules installed", "webRequest saw this URL") so it does not have to
    /// invent a second transport for something M2 already measured as working.
    var onHandshake: (([String: Any]) -> Void)?

    func enable() {
        isEnabled = true
    }

    func reset() {
        chunks.removeAll()
        report = nil
    }

    /// - Returns: `true` when the message was a harness report and has been consumed.
    func ingestNativeMessage(_ message: Any) -> Bool {
        guard isEnabled else { return false }

        // The harness handshakes before sending anything, to find out whether native messaging
        // reaches the delegate at all. It must be acknowledged but never mistaken for the report:
        // an empty report would latch `deliver` and the real one would be dropped on the floor.
        if let dictionary = message as? [String: Any], dictionary["handshake"] as? Bool == true {
            onHandshake?(dictionary)
            return true
        }

        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              var decoded = try? JSONDecoder().decode(WebExtensionProbeReport.self, from: data),
              !decoded.probes.isEmpty else {
            return false
        }
        decoded.channel = "native"
        deliver(decoded)
        return true
    }

    /// - Returns: `true` when the URL was a harness beacon and must not open a real tab.
    func ingestBeacon(url: URL) -> Bool {
        guard isEnabled, url.host?.lowercased() == Self.beaconHost else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let indexText = items.first(where: { $0.name == "i" })?.value,
              let index = Int(indexText),
              let totalText = items.first(where: { $0.name == "n" })?.value,
              let total = Int(totalText),
              let payload = items.first(where: { $0.name == "d" })?.value,
              index >= 0, total > 0, index < total else {
            // Still a harness URL: swallow it rather than opening a tab.
            return true
        }

        chunks[index] = payload
        guard chunks.count == total else { return true }

        var joined = ""
        for position in 0..<total {
            guard let chunk = chunks[position] else { return true }
            joined += chunk
        }

        guard let data = Self.decodeBase64URL(joined),
              var decoded = try? JSONDecoder().decode(WebExtensionProbeReport.self, from: data),
              !decoded.probes.isEmpty else {
            return true
        }

        decoded.channel = "urlBeacon"
        deliver(decoded)
        return true
    }

    private func deliver(_ report: WebExtensionProbeReport) {
        guard self.report == nil else { return }
        self.report = report
        onReport?(report)
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized)
    }
}
