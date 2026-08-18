import Foundation

struct BoundedDirectoryListing {
    let entries: [URL]
    let wasTruncated: Bool
}

/// Enumerates direct children without asking `FileManager` to materialize an unbounded directory.
enum BoundedDirectoryReader {
    static func directChildren(
        of directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey] = [],
        options: FileManager.DirectoryEnumerationOptions = [],
        maximumEntryCount: Int,
        fileManager: FileManager = .default
    ) throws -> BoundedDirectoryListing {
        var enumerationError: Error?
        guard directory.isFileURL, maximumEntryCount > 0,
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: options.union(.skipsSubdirectoryDescendants),
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
              ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var entries: [URL] = []
        entries.reserveCapacity(min(maximumEntryCount, 512))
        while let entry = enumerator.nextObject() as? URL {
            guard entries.count < maximumEntryCount else {
                return BoundedDirectoryListing(entries: entries, wasTruncated: true)
            }
            entries.append(entry)
        }
        if let enumerationError { throw enumerationError }
        return BoundedDirectoryListing(entries: entries, wasTruncated: false)
    }
}
