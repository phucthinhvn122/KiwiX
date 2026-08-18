import Foundation

extension Notification.Name {
    static let browserSettingsDidChange = Notification.Name(
        "ExtensionBrowser.Settings.DidChange"
    )
}

@MainActor
final class BrowserSettingsStore {
    static let shared = BrowserSettingsStore()

    private enum Key {
        static let selectedSearchEngineID = "browser.selectedSearchEngineID"
        static let customSearchEngines = "browser.customSearchEngines"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maximumCustomEngineCount = 32
    private let maximumEncodedBytes = 64 * 1_024

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var customSearchEngines: [SearchEngine] {
        guard let data = defaults.data(forKey: Key.customSearchEngines),
              data.count <= maximumEncodedBytes,
              (try? BoundedJSONPreflight.validate(data, maximumStructuralTokens: 1_024)) != nil,
              let engines = try? decoder.decode([SearchEngine].self, from: data) else {
            return []
        }
        return engines.prefix(maximumCustomEngineCount).filter {
            !$0.isBuiltIn &&
                $0.name.utf8.count <= SearchEngine.maximumNameBytes &&
                SafeInput.isSafeDisplayText($0.name) &&
                SearchEngine.isValid(template: $0.queryURLTemplate)
        }
    }

    var availableSearchEngines: [SearchEngine] {
        SearchEngine.builtInEngines + customSearchEngines
    }

    var selectedSearchEngine: SearchEngine {
        let selectedID = defaults.string(forKey: Key.selectedSearchEngineID)
        return availableSearchEngines.first(where: { $0.id == selectedID }) ?? .google
    }

    func selectSearchEngine(id: String) {
        guard availableSearchEngines.contains(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: Key.selectedSearchEngineID)
        NotificationCenter.default.post(name: .browserSettingsDidChange, object: self)
    }

    @discardableResult
    func addCustomSearchEngine(name: String, template: String) -> SearchEngine? {
        guard let engine = SearchEngine(
            id: "custom.\(UUID().uuidString.lowercased())",
            name: name,
            queryURLTemplate: template
        ) else {
            return nil
        }

        var engines = customSearchEngines
        guard engines.count < maximumCustomEngineCount else { return nil }
        engines.append(engine)
        persistCustomEngines(engines)
        selectSearchEngine(id: engine.id)
        return engine
    }

    func removeCustomSearchEngine(id: String) {
        let remaining = customSearchEngines.filter { $0.id != id }
        guard remaining.count != customSearchEngines.count else { return }
        persistCustomEngines(remaining)
        if defaults.string(forKey: Key.selectedSearchEngineID) == id {
            defaults.set(SearchEngine.google.id, forKey: Key.selectedSearchEngineID)
        }
        NotificationCenter.default.post(name: .browserSettingsDidChange, object: self)
    }

    private func persistCustomEngines(_ engines: [SearchEngine]) {
        guard engines.count <= maximumCustomEngineCount,
              let data = try? encoder.encode(engines),
              data.count <= maximumEncodedBytes else { return }
        defaults.set(data, forKey: Key.customSearchEngines)
    }
}
