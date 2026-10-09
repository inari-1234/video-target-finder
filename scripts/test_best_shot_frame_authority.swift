import AVFoundation
import CoreVideo
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

private func makePixelBuffer(width: Int, height: Int, gray: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        throw TestFailure.failed("Could not create source pixel buffer: \(status)")
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw TestFailure.failed("Missing source pixel buffer base address")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let offset = x * 4
            row[offset + 0] = gray
            row[offset + 1] = gray
            row[offset + 2] = gray
            row[offset + 3] = 255
        }
    }
    return buffer
}

private func makeSyntheticVFRVideo(at url: URL) async throws -> [CMTime] {
    let width = 64
    let height = 64
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
    )
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
    )

    guard writer.canAdd(input) else {
        throw TestFailure.failed("Writer rejected video input")
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw TestFailure.failed("Writer failed to start: \(writer.error?.localizedDescription ?? "unknown")")
    }
    writer.startSession(atSourceTime: .zero)

    // Deliberately irregular presentation intervals: 33, 67, 33, 100, 33 ms.
    let times = [0, 20, 60, 80, 140, 160].map { CMTime(value: CMTimeValue($0), timescale: 600) }
    for (index, time) in times.enumerated() {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let buffer = try makePixelBuffer(width: width, height: height, gray: UInt8(30 + index * 30))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw TestFailure.failed("Writer failed to append frame \(index): \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    input.markAsFinished()
    await withCheckedContinuation { continuation in
        writer.finishWriting {
            continuation.resume()
        }
    }
    guard writer.status == .completed else {
        throw TestFailure.failed("Writer did not complete: \(writer.error?.localizedDescription ?? "unknown")")
    }
    return times
}

@main
struct BestShotFrameAuthorityRuntimeTest {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("best-shot-frame-authority-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceTimes = try await makeSyntheticVFRVideo(at: url)
        let asset = AVURLAsset(url: url)
        let index = try await BestShotFrameAuthority.makeIndex(for: asset)

        try expect(index.frameCount == sourceTimes.count, "PTS index count mismatch: \(index.frameCount) vs \(sourceTimes.count)")
        try expect(index.isVariableFrameRate, "Irregular PTS sequence must be recognized as variable timing")

        for (ordinal, expectedTime) in sourceTimes.enumerated() {
            let indexed = try index.frame(at: ordinal)
            try expect(CMTimeCompare(indexed.time, expectedTime) == 0, "Indexed PTS mismatch at ordinal \(ordinal)")
        }

        for ordinal in [0, 2, sourceTimes.count - 1] {
            let decoded = try await BestShotFrameAuthority.decodeExactFrame(
                from: asset,
                index: index,
                ordinal: ordinal
            )
            try expect(decoded.isExactPTSMatch, "Exact decode mismatch at ordinal \(ordinal)")
            try expect(CVPixelBufferGetWidth(decoded.pixelBuffer) == 64, "Decoded width mismatch")
            try expect(CVPixelBufferGetHeight(decoded.pixelBuffer) == 64, "Decoded height mismatch")
        }

        let constantTimes = [0, 20, 40, 60, 80].map { CMTime(value: CMTimeValue($0), timescale: 600) }
        try expect(!BestShotFrameAuthority.timingIsVariable(constantTimes), "Constant PTS timing incorrectly marked variable")
        try expect(BestShotFrameAuthority.timingIsVariable(sourceTimes), "Variable PTS timing not detected")
        try expect(
            BestShotFrameAuthority.preferredPixelFormat(for: .hlg) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            "HLG must request a 10-bit decode surface"
        )
        try expect(
            BestShotFrameAuthority.preferredPixelFormat(for: .sdr) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            "SDR must request an 8-bit decode surface"
        )

        print("Best-shot PTS authority runtime test: PASS")
        print("frames=\(index.frameCount), vfr=\(index.isVariableFrameRate), dynamicRange=\(index.sourceDynamicRange.rawValue)")
    }
}
