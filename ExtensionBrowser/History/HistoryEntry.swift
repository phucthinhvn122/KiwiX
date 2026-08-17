import Foundation

struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let url: URL
    let visitedAt: Date

    init(id: UUID = UUID(), title: String, url: URL, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
}
