import Foundation

enum BoundedFileReadError: Error, Equatable {
    case invalidFile
    case tooLarge
}

enum BoundedFileReader {
    static func read(
        from url: URL,
        maximumByteCount: Int,
        fileManager: FileManager = .default
    ) throws -> Data {
        guard url.isFileURL, maximumByteCount >= 0 else {
            throw BoundedFileReadError.invalidFile
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BoundedFileReadError.invalidFile
        }
        let declaredSize = values.fileSize ?? 0
        guard declaredSize >= 0, declaredSize <= maximumByteCount else {
            throw BoundedFileReadError.tooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(declaredSize)
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            let remaining = maximumByteCount - data.count
            guard chunk.count <= remaining else { throw BoundedFileReadError.tooLarge }
            data.append(chunk)
        }
        return data
    }
}
