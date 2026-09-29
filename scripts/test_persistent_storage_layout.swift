import Foundation

@main
struct PersistentStorageLayoutTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("VideoTargetFinder-storage-test-\(UUID().uuidString)", isDirectory: true)
        let root = PersistentStorageLayout.rootURL(in: base)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let manifest = PersistentStorageLayout.scanManifestURL(in: root)
        let refs = PersistentStorageLayout.scanReferenceFolderURL(in: root)
        let report = PersistentStorageLayout.recognitionReportURL(in: root)
        let log = PersistentStorageLayout.diagnosticLogURL(in: root)

        try Data("checkpoint".utf8).write(to: manifest)
        try fm.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data("reference".utf8).write(to: refs.appendingPathComponent("00.jpg"))
        try Data("report".utf8).write(to: report)
        try Data("log".utf8).write(to: log)

        PersistentStorageLayout.clearScanCheckpoint(in: root, fileManager: fm)

        precondition(!fm.fileExists(atPath: manifest.path))
        precondition(!fm.fileExists(atPath: refs.path))
        precondition(fm.fileExists(atPath: report.path))
        precondition(fm.fileExists(atPath: log.path))
        precondition(fm.fileExists(atPath: root.path))

        try? fm.removeItem(at: base)
        print("PersistentStorageLayout tests: PASS")
    }
}
