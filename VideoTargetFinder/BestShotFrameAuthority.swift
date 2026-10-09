@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// B-series remains isolated from the production recognition path until each gate passes.
enum BestShotFeatureFlags {
    static let frameAuthorityDiagnosticsEnabled = false
}

enum BestShotDynamicRange: String, Codable, Sendable {
    case sdr
    case hlg
    case pq
    case unknown
}

struct BestShotFramePTS: Hashable, Codable, Sendable {
    let value: CMTimeValue
    let timescale: CMTimeScale

    init(_ time: CMTime) {
        let normalized = time.convertScale(max(1, time.timescale), method: .default)
        value = normalized.value
        timescale = normalized.timescale
    }

    var time: CMTime {
        CMTime(value: value, timescale: timescale)
    }

    var seconds: TimeInterval {
        CMTimeGetSeconds(time)
    }
}

struct BestShotFrameIndex: @unchecked Sendable {
    let trackID: CMPersistentTrackID
    let frames: [BestShotFramePTS]
    /// Each presentation frame's nearest preceding sync sample in decode order.
    /// This is deliberately parallel to `frames` so B1/B2 navigation remains PTS-based.
    let decodeStartPTS: [BestShotFramePTS]
    let nominalFrameRate: Float
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let sourceDynamicRange: BestShotDynamicRange
    let isVariableFrameRate: Bool

    var frameCount: Int { frames.count }

    func frame(at ordinal: Int) throws -> BestShotFramePTS {
        guard frames.indices.contains(ordinal) else {
            throw BestShotFrameAuthorityError.ordinalOutOfRange(ordinal)
        }
        return frames[ordinal]
    }

    func decodeStart(at ordinal: Int) throws -> BestShotFramePTS {
        guard decodeStartPTS.indices.contains(ordinal) else {
            throw BestShotFrameAuthorityError.ordinalOutOfRange(ordinal)
        }
        return decodeStartPTS[ordinal]
    }
}

struct BestShotDecodedFrame {
    let expectedPTS: BestShotFramePTS
    let actualPTS: BestShotFramePTS
    let pixelBuffer: CVPixelBuffer
    let pixelFormat: OSType

    var isExactPTSMatch: Bool {
        CMTimeCompare(expectedPTS.time, actualPTS.time) == 0
    }
}

enum BestShotFrameAuthorityError: Error, LocalizedError {
    case noVideoTrack
    case readerOutputRejected
    case readerStartFailed(String)
    case readerFailed(String)
    case emptyPresentationIndex
    case ordinalOutOfRange(Int)
    case missingPixelBuffer
    case exactFrameNotFound(expected: BestShotFramePTS, nearest: BestShotFramePTS?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "動画トラックを取得できませんでした。"
        case .readerOutputRejected:
            return "動画Readerの出力を追加できませんでした。"
        case .readerStartFailed(let detail):
            return "動画Readerを開始できませんでした: \(detail)"
        case .readerFailed(let detail):
            return "動画Readerでフレームを読み取れませんでした: \(detail)"
        case .emptyPresentationIndex:
            return "動画から表示時刻（PTS）を取得できませんでした。"
        case .ordinalOutOfRange(let ordinal):
            return "フレーム番号が範囲外です: \(ordinal)"
        case .missingPixelBuffer:
            return "デコード済みフレームのPixelBufferを取得できませんでした。"
        case .exactFrameNotFound(let expected, let nearest):
            let expectedText = String(format: "%.6f", expected.seconds)
            let nearestText = nearest.map { String(format: "%.6f", $0.seconds) } ?? "なし"
            return "指定PTSと同一フレームを取得できませんでした。expected=\(expectedText), nearest=\(nearestText)"
        }
    }
}

private struct BestShotCompressedFrameRecord {
    let pts: CMTime
    let decodeStartPTS: CMTime
}

/// Best-shot B0-A authority.
///
/// - Compressed samples are read in decode order without pixel decoding.
/// - Only displayable samples with encoded payload enter the presentation PTS authority.
/// - Each frame retains the nearest preceding sync sample as its decode anchor.
/// - The sorted unique PTS list remains the only frame-navigation authority for B1/B2.
/// - Decoding starts at the sync anchor and must return the exact requested PTS;
///   silent snapping to a neighboring frame is forbidden.
/// - HDR sources request a 10-bit YCbCr pixel buffer so B1 can preserve HDR without first forcing SDR.
final class BestShotFrameAuthority {
    static func makeIndex(for asset: AVAsset) async throws -> BestShotFrameIndex {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BestShotFrameAuthorityError.noVideoTrack
        }
        let trackTimeRange = try await track.load(.timeRange)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw BestShotFrameAuthorityError.readerOutputRejected
        }
        reader.add(output)

        guard reader.startReading() else {
            throw BestShotFrameAuthorityError.readerStartFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var records: [BestShotCompressedFrameRecord] = []
        records.reserveCapacity(2_000)
        var currentSyncPTS: CMTime?

        while let sample = output.copyNextSampleBuffer() {
            // Encoders/readers can surface timing-only buffers. They are not still-image frames.
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  CMSampleBufferGetTotalSampleSize(sample) > 0,
                  !sampleAttachmentBool(sample, key: kCMSampleAttachmentKey_DoNotDisplay) else {
                continue
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid && pts.isNumeric else { continue }

            // nil outputSettings returns encoded samples in decode order. Preserve that order
            // long enough to associate each frame with the most recent independent sync sample.
            if !sampleAttachmentBool(sample, key: kCMSampleAttachmentKey_NotSync) {
                currentSyncPTS = pts
            }
            let decodeStart = currentSyncPTS ?? trackTimeRange.start
            records.append(BestShotCompressedFrameRecord(pts: pts, decodeStartPTS: decodeStart))
        }

        if reader.status == .failed {
            throw BestShotFrameAuthorityError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        records.sort { CMTimeCompare($0.pts, $1.pts) < 0 }
        var uniqueRecords: [BestShotCompressedFrameRecord] = []
        uniqueRecords.reserveCapacity(records.count)
        for record in records {
            if let previous = uniqueRecords.last, CMTimeCompare(previous.pts, record.pts) == 0 {
                continue
            }
            uniqueRecords.append(record)
        }

        guard !uniqueRecords.isEmpty else {
            throw BestShotFrameAuthorityError.emptyPresentationIndex
        }

        async let nominalFrameRate = track.load(.nominalFrameRate)
        async let naturalSize = track.load(.naturalSize)
        async let preferredTransform = track.load(.preferredTransform)
        async let formatDescriptions = track.load(.formatDescriptions)

        let presentationTimes = uniqueRecords.map(\.pts)
        let frames = presentationTimes.map(BestShotFramePTS.init)
        let decodeStarts = uniqueRecords.map { BestShotFramePTS($0.decodeStartPTS) }
        let dynamicRange = dynamicRange(from: try await formatDescriptions)

        return BestShotFrameIndex(
            trackID: track.trackID,
            frames: frames,
            decodeStartPTS: decodeStarts,
            nominalFrameRate: try await nominalFrameRate,
            naturalSize: try await naturalSize,
            preferredTransform: try await preferredTransform,
            sourceDynamicRange: dynamicRange,
            isVariableFrameRate: timingIsVariable(presentationTimes)
        )
    }

    static func decodeExactFrame(
        from asset: AVAsset,
        index: BestShotFrameIndex,
        ordinal: Int
    ) async throws -> BestShotDecodedFrame {
        let expected = try index.frame(at: ordinal)
        let decodeAnchor = try index.decodeStart(at: ordinal)
        guard let track = try await asset.loadTracks(withMediaType: .video)
            .first(where: { $0.trackID == index.trackID }) else {
            throw BestShotFrameAuthorityError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let pixelFormat = preferredPixelFormat(for: index.sourceDynamicRange)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw BestShotFrameAuthorityError.readerOutputRejected
        }
        reader.add(output)

        let targetTime = expected.time
        let assetDuration = try await asset.load(.duration)
        var startTime = decodeAnchor.time
        if CMTimeCompare(startTime, targetTime) > 0 {
            // Defensive fallback for unusual reordered streams: never start after the target PTS.
            startTime = try await track.load(.timeRange).start
        }

        let endTime: CMTime
        if ordinal + 1 < index.frames.count {
            endTime = index.frames[ordinal + 1].time
        } else {
            endTime = assetDuration
        }
        let rawDuration = CMTimeSubtract(endTime, startTime)
        let minimumDuration = CMTime(seconds: 1.0, preferredTimescale: max(600, targetTime.timescale))
        let duration = CMTimeCompare(rawDuration, .zero) > 0 ? rawDuration : minimumDuration
        reader.timeRange = CMTimeRange(start: startTime, duration: duration)

        guard reader.startReading() else {
            throw BestShotFrameAuthorityError.readerStartFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var nearest: BestShotFramePTS?
        var nearestDelta = Double.greatestFiniteMagnitude

        while let sample = output.copyNextSampleBuffer() {
            let actualTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard actualTime.isValid && actualTime.isNumeric else { continue }
            let actual = BestShotFramePTS(actualTime)
            let delta = abs(actual.seconds - expected.seconds)
            if delta < nearestDelta {
                nearest = actual
                nearestDelta = delta
            }

            if CMTimeCompare(actualTime, targetTime) == 0 {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw BestShotFrameAuthorityError.missingPixelBuffer
                }
                return BestShotDecodedFrame(
                    expectedPTS: expected,
                    actualPTS: actual,
                    pixelBuffer: pixelBuffer,
                    pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
                )
            }

            // Decoded AVAssetReader output is in presentation order. Once it has passed
            // the target, that exact frame cannot appear later in this read.
            if CMTimeCompare(actualTime, targetTime) > 0 {
                break
            }
        }

        if reader.status == .failed {
            throw BestShotFrameAuthorityError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        throw BestShotFrameAuthorityError.exactFrameNotFound(expected: expected, nearest: nearest)
    }

    static func preferredPixelFormat(for dynamicRange: BestShotDynamicRange) -> OSType {
        switch dynamicRange {
        case .hlg, .pq:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .sdr, .unknown:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    static func timingIsVariable(_ sortedPTS: [CMTime]) -> Bool {
        guard sortedPTS.count >= 4 else { return false }
        let intervals = zip(sortedPTS.dropFirst(), sortedPTS).compactMap { current, previous -> Double? in
            let seconds = CMTimeGetSeconds(CMTimeSubtract(current, previous))
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        guard intervals.count >= 3 else { return false }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let tolerance = max(0.0005, median * 0.02)
        return intervals.contains { abs($0 - median) > tolerance }
    }

    private static func sampleAttachmentBool(_ sample: CMSampleBuffer, key: CFString) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: false
        ) as? [NSDictionary],
        let first = attachments.first else {
            return false
        }
        if let value = first[key] as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private static func dynamicRange(from descriptions: [CMFormatDescription]) -> BestShotDynamicRange {
        var sawKnownSDR = false
        for description in descriptions {
            guard let rawExtensions = CMFormatDescriptionGetExtensions(description) else {
                continue
            }
            let extensions = rawExtensions as NSDictionary
            guard let transfer = extensions[kCVImageBufferTransferFunctionKey as String] as? String else {
                continue
            }
            if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                return .hlg
            }
            if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
                return .pq
            }
            if transfer == (kCVImageBufferTransferFunction_ITU_R_709_2 as String) ||
                transfer == (kCVImageBufferTransferFunction_sRGB as String) {
                sawKnownSDR = true
            }
        }
        return sawKnownSDR ? .sdr : .unknown
    }
}
