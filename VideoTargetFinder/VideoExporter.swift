@preconcurrency import AVFoundation
import Foundation

@MainActor
enum VideoExporter {
    enum ExportError: LocalizedError {
        case cannotCreateSession
        case unsupportedFileType(AVFileType)
        case noVideoTrack
        case cannotCreateCompositionTrack
        case noValidRanges

        var errorDescription: String? {
            switch self {
            case .cannotCreateSession:
                return "動画の書き出しセッションを作成できませんでした。"
            case .unsupportedFileType(let type):
                return "この動画では \(type.rawValue) 形式を書き出せません。"
            case .noVideoTrack:
                return "元動画の映像トラックを取得できませんでした。"
            case .cannotCreateCompositionTrack:
                return "結合用の映像トラックを作成できませんでした。"
            case .noValidRanges:
                return "書き出せる有効な動画区間がありません。"
            }
        }
    }

    static func exportClip(
        asset: AVAsset,
        range: ExportTimeRange,
        format: ExportFormat,
        filenameStem: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        DiagnosticLogger.log("Export clip: creating session preset=\(format.presetName), range=\(range.start)-\(range.end)")
        guard let session = AVAssetExportSession(asset: asset, presetName: format.presetName) else {
            throw ExportError.cannotCreateSession
        }

        guard session.supportedFileTypes.contains(format.fileType) else {
            throw ExportError.unsupportedFileType(format.fileType)
        }

        session.timeRange = range.cmTimeRange
        let outputURL = try makeOutputURL(stem: filenameStem, ext: format.fileExtension)
        try await run(session: session, outputURL: outputURL, fileType: format.fileType, progress: progress)
        return outputURL
    }

    static func exportCombined(
        asset: AVAsset,
        ranges: [ExportTimeRange],
        format: ExportFormat,
        filenameStem: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        DiagnosticLogger.log("Combined export step 1: start ranges=\(ranges.count), format=\(format.rawValue)")
        guard !ranges.isEmpty else { throw ExportError.noValidRanges }

        let assetDuration = try await asset.load(.duration)
        let durationSeconds = assetDuration.seconds
        DiagnosticLogger.log("Combined export step 2: asset duration=\(durationSeconds)")

        let safeRanges = ranges.compactMap { range -> ExportTimeRange? in
            let start = max(0, range.start)
            let end = min(durationSeconds.isFinite ? durationSeconds : range.end, range.end)
            guard start.isFinite, end.isFinite, end - start > 0.01 else { return nil }
            return ExportTimeRange(start: start, end: end)
        }
        guard !safeRanges.isEmpty else { throw ExportError.noValidRanges }

        let composition = AVMutableComposition()
        DiagnosticLogger.log("Combined export step 3: loading tracks")
        let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = sourceVideoTracks.first else {
            throw ExportError.noVideoTrack
        }

        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.cannotCreateCompositionTrack
        }

        if let transform = try? await sourceVideo.load(.preferredTransform) {
            compositionVideo.preferredTransform = transform
        }

        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let compositionAudio: AVMutableCompositionTrack? = sourceAudio == nil
            ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        DiagnosticLogger.log("Combined export step 4: inserting \(safeRanges.count) ranges")
        var insertionTime = CMTime.zero
        for (index, range) in safeRanges.enumerated() {
            try Task.checkCancellation()
            let timeRange = range.cmTimeRange
            DiagnosticLogger.log("Combined export insert \(index + 1)/\(safeRanges.count): \(range.start)-\(range.end)")
            try compositionVideo.insertTimeRange(timeRange, of: sourceVideo, at: insertionTime)
            if let sourceAudio, let compositionAudio {
                do {
                    try compositionAudio.insertTimeRange(timeRange, of: sourceAudio, at: insertionTime)
                } catch {
                    // 音声トラックの一部欠落で映像全体を書き出せなくなるより、映像を優先する。
                    DiagnosticLogger.log("Combined export audio insert warning: \(error.localizedDescription)")
                }
            }
            insertionTime = CMTimeAdd(insertionTime, timeRange.duration)

            let preparationFraction = Double(index + 1) / Double(safeRanges.count)
            progress(min(0.10, preparationFraction * 0.10))
            await Task.yield()
        }

        // Stage 14: composition + Passthrough は実機でプロセス終了を起こしたため、
        // 結合時はMOVでもHighestQualityへ切り替え、再エンコードして安定性を優先する。
        let preset = format.combinedPresetName
        DiagnosticLogger.log("Combined export step 5: creating session preset=\(preset)")
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ExportError.cannotCreateSession
        }
        guard session.supportedFileTypes.contains(format.fileType) else {
            throw ExportError.unsupportedFileType(format.fileType)
        }

        session.shouldOptimizeForNetworkUse = false
        let outputURL = try makeOutputURL(stem: filenameStem, ext: format.fileExtension)
        DiagnosticLogger.log("Combined export step 6: export begin output=\(outputURL.lastPathComponent)")
        try await run(
            session: session,
            outputURL: outputURL,
            fileType: format.fileType,
            progress: { value in
                progress(0.10 + value * 0.90)
            }
        )
        DiagnosticLogger.log("Combined export step 7: export finished")
        return outputURL
    }

    static func removeTemporaryFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func run(
        session: AVAssetExportSession,
        outputURL: URL,
        fileType: AVFileType,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        defer { progressTask.cancel() }

        do {
            try await session.export(to: outputURL, as: fileType)
            progress(1)
        } catch {
            DiagnosticLogger.log("Export session error: \(error.localizedDescription)")
            removeTemporaryFile(outputURL)
            throw error
        }
    }

    private static func makeOutputURL(stem: String, ext: String) throws -> URL {
        try PendingExportStore.makeOutputURL(stem: stem, ext: ext)
    }
}
