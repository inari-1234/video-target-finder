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

/// Best-shot B0-A authority.
///
/// - Presentation timestamps are collected from compressed samples with AVAssetReader.
/// - The sorted unique PTS list is the only frame-navigation authority for B1/B2.
/// - Decoding must return the exact requested PTS; silent snapping to a neighboring frame is forbidden.
/// - HDR sources request a 10-bit YCbCr pixel buffer so B1 can preserve HDR without first forcing SDR.
final class BestShotFrameAuthority {
    static func makeIndex(for asset: AVAsset) async throws -> BestShotFrameIndex {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BestShotFrameAuthorityError.noVideoTrack
        }

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

        var rawPTS: [CMTime] = []
        rawPTS.reserveCapacity(2_000)
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts.isValid && pts.isNumeric {
                rawPTS.append(pts)
            }
        }

        if reader.status == .failed {
            throw BestShotFrameAuthorityError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        rawPTS.sort { CMTimeCompare($0, $1) < 0 }
        var uniquePTS: [CMTime] = []
        uniquePTS.reserveCapacity(rawPTS.count)
        for pts in rawPTS {
            if let previous = uniquePTS.last, CMTimeCompare(previous, pts) == 0 {
                continue
            }
            uniquePTS.append(pts)
        }

        guard !uniquePTS.isEmpty else {
            throw BestShotFrameAuthorityError.emptyPresentationIndex
        }

        async let nominalFrameRate = track.load(.nominalFrameRate)
        async let naturalSize = track.load(.naturalSize)
        async let preferredTransform = track.load(.preferredTransform)
        async let formatDescriptions = track.load(.formatDescriptions)

        let frames = uniquePTS.map(BestShotFramePTS.init)
        let dynamicRange = dynamicRange(from: try await formatDescriptions)

        return BestShotFrameIndex(
            trackID: track.trackID,
            frames: frames,
            nominalFrameRate: try await nominalFrameRate,
            naturalSize: try await naturalSize,
            preferredTransform: try await preferredTransform,
            sourceDynamicRange: dynamicRange,
            isVariableFrameRate: timingIsVariable(uniquePTS)
        )
    }

    static func decodeExactFrame(
        from asset: AVAsset,
        index: BestShotFrameIndex,
        ordinal: Int
    ) async throws -> BestShotDecodedFrame {
        let expected = try index.frame(at: ordinal)
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
        let duration: CMTime
        if ordinal + 1 < index.frames.count {
            let next = index.frames[ordinal + 1].time
            let interval = CMTimeSubtract(next, targetTime)
            duration = CMTimeMaximum(interval, CMTime(value: 1, timescale: max(1, targetTime.timescale)))
        } else {
            duration = CMTime(seconds: 1.0, preferredTimescale: max(600, targetTime.timescale))
        }
        reader.timeRange = CMTimeRange(start: targetTime, duration: duration)

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

            guard CMTimeCompare(actualTime, targetTime) == 0 else { continue }
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
