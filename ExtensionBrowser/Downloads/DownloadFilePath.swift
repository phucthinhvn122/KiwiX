import Foundation

enum DownloadFilePathError: LocalizedError {
    case unableToCreateUniqueDestination

    var errorDescription: String? {
        switch self {
        case .unableToCreateUniqueDestination:
            return "A unique destination could not be created for this download."
        }
    }
}

enum DownloadFilePath {
    static let maximumFilenameByteCount = 180

    static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    static func sanitizedFilename(_ suggestedFilename: String?) -> String {
        var candidate = (suggestedFilename ?? "")
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
        candidate = (candidate as NSString).lastPathComponent

        let unsafeCharacters = CharacterSet.controlCharacters
            .union(.newlines)
            .union(.illegalCharacters)
            .union(CharacterSet(charactersIn: "/\\:"))
        candidate = String(candidate.unicodeScalars.filter { scalar in
            guard !unsafeCharacters.contains(scalar) else { return false }
            // Strip bidi/zero-width formatting characters that can disguise the filename.
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF:
                return false
            default:
                return true
            }
        })
        candidate = candidate.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        )

        if candidate.isEmpty || candidate == "." || candidate == ".." {
            candidate = "Download"
        }

        let reservedWindowsNames: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        ]
        let basename = (candidate as NSString).deletingPathExtension.uppercased()
        if reservedWindowsNames.contains(basename) {
            candidate = "_\(candidate)"
        }

        candidate = truncatingUTF8(candidate, to: maximumFilenameByteCount)
        candidate = candidate.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        )
        return candidate.isEmpty ? "Download" : candidate
    }

    static func uniqueDestination(
        in directoryURL: URL,
        suggestedFilename: String?,
        fileManager: FileManager = .default
    ) throws -> URL {
        let safeName = sanitizedFilename(suggestedFilename)
        let pathExtension = (safeName as NSString).pathExtension
        let basename = (safeName as NSString).deletingPathExtension

        for index in 0..<10_000 {
            let proposedName: String
            if index == 0 {
                proposedName = safeName
            } else if pathExtension.isEmpty {
                proposedName = "\(basename) (\(index + 1))"
            } else {
                proposedName = "\(basename) (\(index + 1)).\(pathExtension)"
            }
            let candidate = directoryURL.appendingPathComponent(
                sanitizedFilename(proposedName),
                isDirectory: false
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw DownloadFilePathError.unableToCreateUniqueDestination
    }

    static func isDirectChild(_ candidateURL: URL, of directoryURL: URL) -> Bool {
        guard candidateURL.isFileURL, directoryURL.isFileURL else { return false }
        let canonicalDirectory = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCandidate = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalCandidate.deletingLastPathComponent() == canonicalDirectory else {
            return false
        }
        return canonicalCandidate.lastPathComponent == sanitizedFilename(canonicalCandidate.lastPathComponent)
    }

    private static func truncatingUTF8(_ value: String, to maximumByteCount: Int) -> String {
        guard value.utf8.count > maximumByteCount else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maximumByteCount))
        for character in value {
            let next = result + String(character)
            guard next.utf8.count <= maximumByteCount else { break }
            result = next
        }
        return result
    }
}
