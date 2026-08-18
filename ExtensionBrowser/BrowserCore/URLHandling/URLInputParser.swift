import Foundation

enum URLInputResolution: Equatable {
    case url(URL)
    case search(URL)

    var url: URL {
        switch self {
        case .url(let url), .search(let url):
            return url
        }
    }
}

protocol URLInputResolving {
    func resolve(_ input: String) -> URLInputResolution?
}

struct URLInputParser: URLInputResolving {
    let searchEngine: SearchEngine

    func resolve(_ input: String) -> URLInputResolution? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= SafePersistence.maximumURLBytes else { return nil }

        if let explicitURL = explicitWebURL(from: value) {
            return .url(explicitURL)
        }
        // A malformed explicit URL must not be sent to the configured search provider, where
        // embedded credentials or secrets could leak as a query.
        if value.contains("://") { return nil }

        if let inferredURL = inferredWebURL(from: value) {
            return .url(inferredURL)
        }

        guard let searchURL = searchEngine.searchURL(for: value) else { return nil }
        return .search(searchURL)
    }

    private func explicitWebURL(from value: String) -> URL? {
        if value.caseInsensitiveCompare("about:blank") == .orderedSame {
            return URL(string: "about:blank")
        }

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.user == nil,
              components.password == nil,
              let host = components.host,
              isPlausible(host: host),
              components.url != nil else {
            return nil
        }
        return components.url
    }

    private func inferredWebURL(from value: String) -> URL? {
        guard !value.contains(where: { $0.isWhitespace }),
              !value.contains("@"),
              !value.contains("://") else {
            return nil
        }

        let candidate = "https://\(value)"
        guard let components = URLComponents(string: candidate),
              let host = components.host,
              isPlausible(host: host) else {
            return nil
        }
        var normalizedComponents = components
        let normalizedHost = host.lowercased()
        if normalizedHost == "localhost" || isIPv4Address(normalizedHost) || normalizedHost.contains(":") {
            normalizedComponents.scheme = "http"
        }
        return normalizedComponents.url
    }

    private func isPlausible(host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty else { return false }

        if normalized == "localhost" || isIPv4Address(normalized) || normalized.contains(":") {
            return true
        }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private func isIPv4Address(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isNumber }),
                  let value = Int(component) else {
                return false
            }
            return (0...255).contains(value)
        }
    }
}
