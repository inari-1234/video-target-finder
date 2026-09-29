import Foundation

enum PendingExportStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VideoTargetFinder Exports", isDirectory: true)
    }

    static func makeOutputURL(stem: String, ext: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)

        let safeStem = stem.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safeStem).\(ext)")
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        return url
    }

    static func list() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func formattedSize(_ url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: fileSize(url), countStyle: .file)
    }
}
