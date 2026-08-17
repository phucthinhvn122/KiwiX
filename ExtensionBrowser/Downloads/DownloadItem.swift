import Foundation

enum DownloadStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case downloading
    case completed
    case failed
    case cancelled

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .downloading:
            return false
        }
    }
}

struct DownloadItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var sourceURL: URL?
    var fileName: String
    var localFileURL: URL?
    var mimeType: String?
    var bytesReceived: Int64
    var totalBytesExpected: Int64?
    var status: DownloadStatus
    var errorDescription: String?
    let isPrivate: Bool
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        sourceURL: URL?,
        fileName: String = "Download",
        localFileURL: URL? = nil,
        mimeType: String? = nil,
        bytesReceived: Int64 = 0,
        totalBytesExpected: Int64? = nil,
        status: DownloadStatus = .queued,
        errorDescription: String? = nil,
        isPrivate: Bool,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.localFileURL = localFileURL
        self.mimeType = mimeType
        self.bytesReceived = max(0, bytesReceived)
        self.totalBytesExpected = totalBytesExpected.flatMap { $0 > 0 ? $0 : nil }
        self.status = status
        self.errorDescription = errorDescription
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    var progress: Double? {
        guard let totalBytesExpected, totalBytesExpected > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytesExpected)))
    }
}
