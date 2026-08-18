import Foundation

struct SearchEngine: Codable, Hashable, Identifiable, Sendable {
    static let maximumNameBytes = 128
    static let maximumTemplateBytes = 2_048
    static let maximumQueryBytes = 2_048
    let id: String
    var name: String
    var queryURLTemplate: String
    var isBuiltIn: Bool

    init?(
        id: String,
        name: String,
        queryURLTemplate: String,
        isBuiltIn: Bool = false
    ) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              !cleanName.isEmpty,
              cleanName.utf8.count <= Self.maximumNameBytes,
              SafeInput.isSafeDisplayText(cleanName),
              queryURLTemplate.utf8.count <= Self.maximumTemplateBytes,
              Self.isValid(template: queryURLTemplate) else {
            return nil
        }

        self.id = id
        self.name = cleanName
        self.queryURLTemplate = queryURLTemplate
        self.isBuiltIn = isBuiltIn
    }

    func searchURL(for query: String) -> URL? {
        guard query.utf8.count <= Self.maximumQueryBytes else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: queryURLTemplate.replacingOccurrences(of: "{query}", with: encodedQuery))
    }

    static func isValid(template: String) -> Bool {
        guard template.contains("{query}") else { return false }
        guard template.utf8.count <= maximumTemplateBytes else { return false }
        let candidate = template.replacingOccurrences(of: "{query}", with: "extensionbrowser")
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return true
    }

    static let google = SearchEngine(
        id: "google",
        name: "Google",
        queryURLTemplate: "https://www.google.com/search?q={query}",
        isBuiltIn: true
    )!

    static let duckDuckGo = SearchEngine(
        id: "duckduckgo",
        name: "DuckDuckGo",
        queryURLTemplate: "https://duckduckgo.com/?q={query}",
        isBuiltIn: true
    )!

    static let bing = SearchEngine(
        id: "bing",
        name: "Bing",
        queryURLTemplate: "https://www.bing.com/search?q={query}",
        isBuiltIn: true
    )!

    static let brave = SearchEngine(
        id: "brave",
        name: "Brave Search",
        queryURLTemplate: "https://search.brave.com/search?q={query}",
        isBuiltIn: true
    )!

    static let builtInEngines: [SearchEngine] = [.google, .duckDuckGo, .bing, .brave]
}
