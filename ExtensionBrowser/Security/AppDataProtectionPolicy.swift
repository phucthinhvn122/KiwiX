import Foundation

enum AppDataProtectionPolicy {
    enum Category {
        case browserState
        case download
        case temporarySensitive

        var protection: FileProtectionType {
            switch self {
            case .browserState: return .completeUntilFirstUserAuthentication
            case .download: return .completeUnlessOpen
            case .temporarySensitive: return .complete
            }
        }
    }

    static func apply(
        to url: URL,
        category: Category,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.setAttributes([.protectionKey: category.protection], ofItemAtPath: url.path)
    }

    static func protectRecursively(
        _ root: URL,
        category: Category,
        fileManager: FileManager = .default
    ) throws {
        try apply(to: root, category: category, fileManager: fileManager)
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            try apply(to: url, category: category, fileManager: fileManager)
        }
    }
}
