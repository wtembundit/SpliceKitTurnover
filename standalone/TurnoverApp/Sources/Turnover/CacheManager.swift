import Foundation

enum CacheManager {
    static let retentionDays = 7
    static let maximumBytes: Int64 = 500 * 1_024 * 1_024

    static var inboxURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Turnover/Inbox", isDirectory: true)
    }

    static func prepareAndClean() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        let files = try cachedFiles()
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)

        for file in files where file.date < cutoff {
            try? manager.removeItem(at: file.url)
        }

        var remaining = try cachedFiles().sorted { $0.date < $1.date }
        var total = remaining.reduce(Int64(0)) { $0 + $1.size }
        while total > maximumBytes, let oldest = remaining.first {
            try? manager.removeItem(at: oldest.url)
            total -= oldest.size
            remaining.removeFirst()
        }
    }

    static func clear() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: inboxURL.path) {
            try manager.removeItem(at: inboxURL)
        }
        try manager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    }

    static func size() -> Int64 {
        (try? cachedFiles().reduce(Int64(0)) { $0 + $1.size }) ?? 0
    }

    private static func cachedFiles() throws -> [(url: URL, size: Int64, date: Date)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: inboxURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}
