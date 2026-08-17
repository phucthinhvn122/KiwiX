import Foundation
import os.signpost

enum PerformanceProfiler {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.extensionbrowser.app",
        category: .pointsOfInterest
    )

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    static func begin(_ name: StaticString) -> Interval {
        Interval(log: log, name: name)
    }

    final class Interval {
        private let log: OSLog
        private let name: StaticString
        private let identifier: OSSignpostID
        private var hasEnded = false

        fileprivate init(log: OSLog, name: StaticString) {
            self.log = log
            self.name = name
            identifier = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: name, signpostID: identifier)
        }

        func end() {
            guard !hasEnded else { return }
            hasEnded = true
            os_signpost(.end, log: log, name: name, signpostID: identifier)
        }

        deinit {
            end()
        }
    }
}
