import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

@main
enum VideoPipelineRuntimeSmokeTests {
    static let width = 256
    static let height = 256
    static let fps: Int32 = 8
    static let frameCount = 32

    static func makePixelBuffer(frameIndex: Int) -> CVPixelBuffer {
        var maybeBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &maybeBuffer
        )
        precondition(status == kCVReturnSuccess)
        guard let buffer = maybeBuffer else { fatalError("CVPixelBuffer creation failed") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            fatalError("Bitmap context creation failed")
        }

        if frameIndex >= 24 {
            context.setFillColor(red: 0.82, green: 0.86, blue: 0.92, alpha: 1)
        } else {
            context.setFillColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if frameIndex < 8 || frameIndex >= 24 {
            let localIndex = frameIndex < 8 ? frameIndex : frameIndex - 24
            let x = 64 + localIndex * 3
            let target = CGRect(x: x, y: 68, width: 96, height: 120)
            context.setFillColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1)
            context.fill(target)

            let cell: CGFloat = 16
            let inset = target.insetBy(dx: 8, dy: 8)
            for row in 0..<6 {
                for column in 0..<5 {
                    let even = (row + column) % 2 == 0
                    context.setFillColor(
                        red: even ? 0.08 : 0.82,
                        green: even ? 0.14 : 0.26,
                        blue: even ? 0.18 : 0.20,
                        alpha: 1
                    )
                    context.fill(
                        CGRect(
                            x: inset.minX + CGFloat(column) * cell,
                            y: inset.minY + CGFloat(row) * cell,
                            width: cell,
                            height: cell
                        )
                    )
                }
            }

            context.setStrokeColor(red: 1, green: 0.35, blue: 0.12, alpha: 1)
            context.setLineWidth(4)
            context.stroke(target.insetBy(dx: 2, dy: 2))
        } else {
            // Similar-but-wrong target. Frames 8-15 are the learned hard negative (A).
            // Frames 16-23 are an unseen variant (B) with the same silhouette but shifted stripe phase.
            let variantB = frameIndex >= 16
            let localIndex = variantB ? frameIndex - 16 : frameIndex - 8
            let x = 64 + localIndex * 2
            let decoy = CGRect(x: x, y: 68, width: 96, height: 120)

            context.setFillColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1)
            context.fill(decoy)

            let inset = decoy.insetBy(dx: 8, dy: 8)
            let stripeWidth: CGFloat = 12
            for column in 0..<7 {
                let shifted = variantB ? (column + 1) % 2 == 0 : column % 2 == 0
                context.setFillColor(
                    red: shifted ? 0.10 : 0.78,
                    green: shifted ? 0.18 : 0.30,
                    blue: shifted ? 0.72 : 0.16,
                    alpha: 1
                )
                context.fill(
                    CGRect(
                        x: inset.minX + CGFloat(column) * stripeWidth,
                        y: inset.minY,
                        width: stripeWidth,
                        height: inset.height
                    )
                )
            }

            context.setStrokeColor(
                red: variantB ? 0.92 : 0.25,
                green: variantB ? 0.30 : 0.80,
                blue: variantB ? 0.22 : 0.95,
                alpha: 1
            )
            context.setLineWidth(4)
            context.stroke(decoy.insetBy(dx: 2, dy: 2))
        }

        return buffer
    }

    static func makeProductionGenerator(
        asset: AVAsset,
        interval: TimeInterval
    ) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let tolerance = min(0.20, interval / 3)
        generator.requestedTimeToleranceBefore = CMTime(
            seconds: tolerance,
            preferredTimescale: 600
        )
        generator.requestedTimeToleranceAfter = CMTime(
            seconds: tolerance,
            preferredTimescale: 600
        )
        return generator
    }

    static func writeFixtureVideo(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
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

        precondition(writer.canAdd(input))
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            precondition(adaptor.append(makePixelBuffer(frameIndex: index), withPresentationTime: time))
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? NSError(
                domain: "VideoPipelineRuntimeSmokeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter did not complete"]
            )
        }
    }

    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-target-finder-runtime-fixture.mov")

        try await writeFixtureVideo(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        precondition(duration > 1.0, "Fixture video duration must be readable")

        let exactGenerator = AVAssetImageGenerator(asset: asset)
        exactGenerator.appliesPreferredTrackTransform = true
        exactGenerator.maximumSize = CGSize(width: 512, height: 512)
        exactGenerator.requestedTimeToleranceBefore = .zero
        exactGenerator.requestedTimeToleranceAfter = .zero

        var targetFrames: [CGImage] = []
        for index in 0..<6 {
            let requested = CMTime(value: CMTimeValue(index), timescale: fps)
            let result = try await exactGenerator.image(at: requested)
            precondition(abs(result.actualTime.seconds - requested.seconds) <= 0.13)
            targetFrames.append(result.image)
        }

        let negativeResult = try await exactGenerator.image(
            at: CMTime(value: 12, timescale: fps)
        )
        let negativeFrame = negativeResult.image

        let unseenDecoyResult = try await exactGenerator.image(
            at: CMTime(value: 20, timescale: fps)
        )
        let unseenDecoyFrame = unseenDecoyResult.image

        guard let reference = targetFrames.first else {
            fatalError("Missing decoded reference frame")
        }

        let secondReferenceResult = try await exactGenerator.image(
            at: CMTime(value: 24, timescale: fps)
        )
        let secondReference = secondReferenceResult.image

        let oneReferenceMatcher = try FeaturePrintMatcher(
            referenceImages: [reference],
            negativeImages: [negativeFrame]
        )
        let secondAppearanceDistanceFromFirst = try oneReferenceMatcher
            .diagnosticPositiveDistance(for: secondReference)
        let brightBackgroundSingleReferenceMatch = try oneReferenceMatcher.bestMatch(
            in: secondReference,
            mode: .balanced
        )
        print(String(
            format: "Bright-background single-reference diagnostic: rejected=%@ positive=%.4f negative=%.4f",
            brightBackgroundSingleReferenceMatch.rejectedByNegative ? "true" : "false",
            brightBackgroundSingleReferenceMatch.distance,
            brightBackgroundSingleReferenceMatch.negativeDistance ?? -1
        ))

        let matcher = try FeaturePrintMatcher(
            referenceImages: [reference, secondReference],
            negativeImages: [negativeFrame]
        )
        let referenceDistance = try matcher.diagnosticPositiveDistance(for: reference)
        let negativeDistance = try matcher.diagnosticPositiveDistance(for: negativeFrame)
        precondition(referenceDistance < negativeDistance)

        let positiveMatch = try matcher.bestMatch(in: targetFrames[3], mode: .balanced)
        precondition(!positiveMatch.rejectedByNegative)

        let negativeMatch = try matcher.bestMatch(in: negativeFrame, mode: .balanced)
        precondition(negativeMatch.rejectedByNegative)

        let unseenDecoyMatch = try matcher.bestMatch(in: unseenDecoyFrame, mode: .balanced)
        precondition(
            unseenDecoyMatch.rejectedByNegative,
            "Unseen similar decoy must remain rejected by the learned hard negative"
        )
        print(String(
            format: "Unseen similar decoy diagnostic: rejected=%@ positive=%.4f negative=%.4f",
            unseenDecoyMatch.rejectedByNegative ? "true" : "false",
            unseenDecoyMatch.distance,
            unseenDecoyMatch.negativeDistance ?? -1
        ))

        let seedRect = CGRect(
            x: 64.0 / Double(width),
            y: 68.0 / Double(height),
            width: 96.0 / Double(width),
            height: 120.0 / Double(height)
        )
        let tracking = VisionObjectTrackingEngine.track(
            images: targetFrames,
            seedRect: seedRect
        )
        precondition(tracking.count == targetFrames.count)
        precondition(!tracking.contains(where: { $0.requestFailed }))
        let trackedBoxes = tracking.compactMap(\.boundingBox)
        let trackedCount = trackedBoxes.count
        precondition(trackedCount >= 4)
        for rect in trackedBoxes {
            precondition(rect.width > 0 && rect.height > 0)
            precondition(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1)
        }


        let coarseInterval = 0.50
        let coarseGenerator = makeProductionGenerator(
            asset: asset,
            interval: coarseInterval
        )
        let totalCoarseSamples = max(1, Int(ceil(duration / coarseInterval)))
        var coarseScores: [Float] = []
        var coarseCandidates: [ScanPipelinePoint] = []
        var coarseNegativeRejections = 0

        for index in 0..<totalCoarseSamples {
            let seconds = min(max(0, duration - 0.001), Double(index) * coarseInterval)
            do {
                let result = try await coarseGenerator.image(
                    at: CMTime(seconds: seconds, preferredTimescale: 600)
                )
                let match = try matcher.bestMatch(in: result.image, mode: .balanced)
                if match.rejectedByNegative {
                    coarseNegativeRejections += 1
                    coarseScores.append(match.distance + 0.25)
                } else {
                    coarseScores.append(match.distance)
                    ScanPipelineCore.insertDistinct(
                        ScanPipelinePoint(
                            time: result.actualTime.seconds,
                            distance: match.distance
                        ),
                        into: &coarseCandidates,
                        limit: SearchSensitivity.balanced.coarseCandidateLimit,
                        minimumSpacing: max(0.75, coarseInterval * 0.75),
                        time: { $0.time },
                        distance: { $0.distance }
                    )
                }
            } catch {
                continue
            }
        }

        let coarseThreshold = ScanPipelineCore.percentile(
            coarseScores,
            quantile: SearchSensitivity.balanced.candidateQuantile
        ) ?? coarseCandidates.last?.distance ?? .greatestFiniteMagnitude
        precondition(!coarseCandidates.isEmpty)

        let windows = ScanPipelineCore.mergedDetailWindows(
            candidates: coarseCandidates,
            duration: duration,
            radius: SearchSensitivity.balanced.detailRadius
        )
        precondition(!windows.isEmpty)

        let detailInterval = 0.25
        let detailGenerator = makeProductionGenerator(
            asset: asset,
            interval: detailInterval
        )
        let detailThreshold = ScanPipelineCore.detailThreshold(
            coarseThreshold: coarseThreshold
        )
        var detailHits: [ScanPipelinePoint] = []
        var detailNegativeRejections = 0

        for window in windows {
            var time = window.start
            while time <= window.end + 0.0001 {
                do {
                    let result = try await detailGenerator.image(
                        at: CMTime(seconds: time, preferredTimescale: 600)
                    )
                    let match = try matcher.bestMatch(in: result.image, mode: .balanced)
                    if match.rejectedByNegative {
                        detailNegativeRejections += 1
                    } else if match.distance <= detailThreshold {
                        detailHits.append(
                            ScanPipelinePoint(
                                time: result.actualTime.seconds,
                                distance: match.distance
                            )
                        )
                    }
                } catch {
                    // Match production behavior: a single frame failure must not abort the scan.
                }
                time += detailInterval
            }
        }

        detailHits.sort { $0.time < $1.time }
        let segmentPlans = ScanPipelineCore.segmentPlans(
            hits: detailHits,
            duration: duration,
            detailInterval: detailInterval
        )
        precondition(segmentPlans.count == 2, "Two separated target appearances must become two segments")
        precondition(segmentPlans[0].startTime <= 0.5)
        precondition(segmentPlans[0].endTime < segmentPlans[1].startTime)
        precondition(segmentPlans[1].endTime >= 3.0)
        precondition(
            coarseNegativeRejections + detailNegativeRejections > 0,
            "Hard-negative interval must be rejected in production-tolerance replay"
        )

        print(String(
            format: "Video pipeline runtime smoke test: PASS (decoded %d, tracked %d/%d, ref %.4f, neg %.4f, second-vs-first %.4f)",
            targetFrames.count,
            trackedCount,
            targetFrames.count,
            referenceDistance,
            negativeDistance,
            secondAppearanceDistanceFromFirst
        ))
        print("Headless coarse/detail/segment replay: PASS (candidates \(coarseCandidates.count), hits \(detailHits.count), segments \(segmentPlans.count))")
        print("Two-appearance video regression: PASS")
        print("Production-tolerance frame replay: PASS")
        print("Hard-negative interval exclusion: PASS (coarse \(coarseNegativeRejections), detail \(detailNegativeRejections))")
        print("Unseen similar decoy rejection: PASS")
    }
}
