import Foundation

enum RecognitionReportSnapshotStore {
    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func save(_ report: RecognitionQualityReport) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: fileURL, options: .atomic)
    }

    static func load() -> RecognitionQualityReport? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecognitionQualityReport.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static var fileURL: URL {
        PersistentStorageLayout.recognitionReportURL(
            in: PersistentStorageLayout.applicationSupportRoot()
        )
    }
}
