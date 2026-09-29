import Foundation

enum PersistentStorageLayout {
    static let applicationFolderName = "VideoTargetFinder"
    static let scanManifestName = "scan-checkpoint.json"
    static let scanReferenceFolderName = "checkpoint-references"
    static let recognitionReportName = "recognition-quality-report.json"
    static let diagnosticLogName = "diagnostic.log"

    static func rootURL(in base: URL) -> URL {
        base.appendingPathComponent(applicationFolderName, isDirectory: true)
    }

    static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return rootURL(in: base)
    }

    static func scanManifestURL(in root: URL) -> URL {
        root.appendingPathComponent(scanManifestName)
    }

    static func scanReferenceFolderURL(in root: URL) -> URL {
        root.appendingPathComponent(scanReferenceFolderName, isDirectory: true)
    }

    static func recognitionReportURL(in root: URL) -> URL {
        root.appendingPathComponent(recognitionReportName)
    }

    static func diagnosticLogURL(in root: URL) -> URL {
        root.appendingPathComponent(diagnosticLogName)
    }

    static func clearScanCheckpoint(
        in root: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: scanManifestURL(in: root))
        try? fileManager.removeItem(at: scanReferenceFolderURL(in: root))
    }
}
