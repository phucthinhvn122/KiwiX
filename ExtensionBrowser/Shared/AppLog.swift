import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.extensionbrowser.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let browser = Logger(subsystem: subsystem, category: "browser")
    static let tabs = Logger(subsystem: subsystem, category: "tabs")
    static let extensions = Logger(subsystem: subsystem, category: "extensions")
}
