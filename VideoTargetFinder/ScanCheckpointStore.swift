import Foundation
import UIKit

struct PersistedCandidate: Codable {
    let time: TimeInterval
    let distance: Float
    let referenceIndex: Int
    let regionLabel: String
}

struct PersistedCandidateBudgetPoint: Codable {
    let time: TimeInterval
    let distance: Float
}

struct PersistedScanCheckpoint: Codable {
    let version: Int
    let videoAssetIdentifier: String
    let duration: TimeInterval
    let coarseInterval: TimeInterval
    let detailInterval: TimeInterval
    let sensitivityRawValue: String
    let nextFrameIndex: Int
    let scores: [Float]
    let candidates: [PersistedCandidate]
    /// v2以降の分析用軽量reserve。v1ではnil。
    let analysisReserve: [PersistedCandidateBudgetPoint]?
    let createdAt: Date

    var sensitivity: SearchSensitivity {
        SearchSensitivity(rawValue: sensitivityRawValue) ?? .balanced
    }
}

/// Stage 7: アプリが終了しても粗探索の途中位置を復旧できる最小チェックポイント。
/// 見本画像もApplication Support内にJPEGで保存する。
enum ScanCheckpointStore {

    static var exists: Bool {
        FileManager.default.fileExists(atPath: manifestURL.path)
    }

    static func load() throws -> (PersistedScanCheckpoint, [UIImage]) {
        let data = try Data(contentsOf: manifestURL)
        let checkpoint = try JSONDecoder().decode(PersistedScanCheckpoint.self, from: data)

        let folder = referenceFolderURL
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        let images = urls.compactMap { url -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }
        return (checkpoint, images)
    }

    static func save(
        checkpoint: PersistedScanCheckpoint,
        referenceImages: [UIImage],
        writeReferences: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        if writeReferences {
            try? FileManager.default.removeItem(at: referenceFolderURL)
            try FileManager.default.createDirectory(
                at: referenceFolderURL,
                withIntermediateDirectories: true
            )
            for (index, image) in referenceImages.enumerated() {
                guard let data = image.jpegData(compressionQuality: 0.88) else { continue }
                let url = referenceFolderURL.appendingPathComponent(String(format: "%02d.jpg", index))
                try data.write(to: url, options: .atomic)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        try data.write(to: manifestURL, options: .atomic)
    }

    static func clear() {
        PersistentStorageLayout.clearScanCheckpoint(in: rootURL)
    }

    private static var rootURL: URL {
        PersistentStorageLayout.applicationSupportRoot()
    }

    private static var manifestURL: URL {
        PersistentStorageLayout.scanManifestURL(in: rootURL)
    }

    private static var referenceFolderURL: URL {
        PersistentStorageLayout.scanReferenceFolderURL(in: rootURL)
    }
}
