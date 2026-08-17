import Foundation

@MainActor
final class BrowserDiagnostics {
    static let shared = BrowserDiagnostics()

    private(set) var memoryWarningCount = 0
    private(set) var navigationEventCount = 0

    private init() {}

    func recordMemoryWarning() {
        memoryWarningCount += 1
    }

    func recordNavigationEvent() {
        navigationEventCount += 1
    }
}
