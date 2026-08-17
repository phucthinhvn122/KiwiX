import Foundation

public struct WebExtensionManifest: Codable, Equatable, Sendable {
    public let manifestVersion: Int
    public let name: String
    public let version: String
    public let description: String?
    public let permissions: [String]
    public let hostPermissions: [String]
    public let contentScripts: [ContentScript]
    public let action: Action?
    public let icons: [String: String]

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case name
        case version
        case description
        case permissions
        case hostPermissions = "host_permissions"
        case contentScripts = "content_scripts"
        case action
        case icons
    }

    public init(
        manifestVersion: Int,
        name: String,
        version: String,
        description: String? = nil,
        permissions: [String] = [],
        hostPermissions: [String] = [],
        contentScripts: [ContentScript] = [],
        action: Action? = nil,
        icons: [String: String] = [:]
    ) {
        self.manifestVersion = manifestVersion
        self.name = name
        self.version = version
        self.description = description
        self.permissions = permissions
        self.hostPermissions = hostPermissions
        self.contentScripts = contentScripts
        self.action = action
        self.icons = icons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = try container.decode(Int.self, forKey: .manifestVersion)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        hostPermissions = try container.decodeIfPresent([String].self, forKey: .hostPermissions) ?? []
        contentScripts = try container.decodeIfPresent([ContentScript].self, forKey: .contentScripts) ?? []
        action = try container.decodeIfPresent(Action.self, forKey: .action)
        icons = try container.decodeIfPresent([String: String].self, forKey: .icons) ?? [:]
    }

    public struct ContentScript: Codable, Equatable, Sendable, Identifiable {
        public let matches: [String]
        public let excludeMatches: [String]
        public let javascript: [String]
        public let css: [String]
        public let runAt: RunAt
        public let allFrames: Bool

        public var id: String {
            ([runAt.rawValue] + matches + excludeMatches + javascript + css).joined(separator: "\u{1F}")
        }

        enum CodingKeys: String, CodingKey {
            case matches
            case excludeMatches = "exclude_matches"
            case javascript = "js"
            case css
            case runAt = "run_at"
            case allFrames = "all_frames"
        }

        public init(
            matches: [String],
            excludeMatches: [String] = [],
            javascript: [String] = [],
            css: [String] = [],
            runAt: RunAt = .documentIdle,
            allFrames: Bool = false
        ) {
            self.matches = matches
            self.excludeMatches = excludeMatches
            self.javascript = javascript
            self.css = css
            self.runAt = runAt
            self.allFrames = allFrames
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            matches = try container.decodeIfPresent([String].self, forKey: .matches) ?? []
            excludeMatches = try container.decodeIfPresent([String].self, forKey: .excludeMatches) ?? []
            javascript = try container.decodeIfPresent([String].self, forKey: .javascript) ?? []
            css = try container.decodeIfPresent([String].self, forKey: .css) ?? []
            runAt = try container.decodeIfPresent(RunAt.self, forKey: .runAt) ?? .documentIdle
            allFrames = try container.decodeIfPresent(Bool.self, forKey: .allFrames) ?? false
        }
    }

    public enum RunAt: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
        case documentStart = "document_start"
        case documentEnd = "document_end"
        case documentIdle = "document_idle"
    }

    public struct Action: Codable, Equatable, Sendable {
        public let defaultTitle: String?
        public let defaultPopup: String?
        public let defaultIcon: IconReference?

        enum CodingKeys: String, CodingKey {
            case defaultTitle = "default_title"
            case defaultPopup = "default_popup"
            case defaultIcon = "default_icon"
        }

        public init(defaultTitle: String? = nil, defaultPopup: String? = nil, defaultIcon: IconReference? = nil) {
            self.defaultTitle = defaultTitle
            self.defaultPopup = defaultPopup
            self.defaultIcon = defaultIcon
        }
    }

    public enum IconReference: Codable, Equatable, Sendable {
        case path(String)
        case sized([String: String])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let path = try? container.decode(String.self) {
                self = .path(path)
            } else {
                self = .sized(try container.decode([String: String].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .path(let path): try container.encode(path)
            case .sized(let paths): try container.encode(paths)
            }
        }
    }
}
