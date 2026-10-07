import Foundation

struct ScanPipelinePoint: Sendable, Equatable {
    let time: TimeInterval
    let distance: Float
}

struct ScanPipelineObservation: Sendable, Equatable {
    let time: TimeInterval
    let distance: Float
    let rejectedByNegative: Bool
    let isAcceptedHit: Bool
}

struct ScanPipelineTimeWindow: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
}

struct ScanPipelineSegmentPlan: Sendable, Equatable {
    let hitRange: Range<Int>
    let bestHitIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let hitCount: Int
    let trackingScore: Double
}

enum ScanPipelineBridgeReason: String, Sendable, Equatable {
    case missingObservations = "missing-observations"
    case gapExceedsVisualBridgeLimit = "gap-exceeds-visual-bridge-limit"
    case insufficientFlankHits = "insufficient-flank-hits"
    case noInteriorObservations = "no-interior-observations"
    case insufficientObservationCoverage = "insufficient-observation-coverage"
    case hardNegativeVeto = "hard-negative-veto"
    case visualContinuityConfirmed = "visual-continuity-confirmed"
    case missingHitThreshold = "missing-hit-threshold"
    case insufficientWeakEvidence = "insufficient-weak-evidence"
    case midpointEvidenceMissing = "midpoint-evidence-missing"
    case weakEvidenceConfirmed = "weak-evidence-confirmed"
}

struct ScanPipelineBridgeDiagnostic: Sendable, Equatable {
    let leftTime: TimeInterval
    let rightTime: TimeInterval
    let gap: TimeInterval
    let maximumBridgeSpan: TimeInterval
    let shouldBridge: Bool
    let reason: ScanPipelineBridgeReason
    let leftFlankHitCount: Int
    let rightFlankHitCount: Int
    let interiorObservationCount: Int
    let minimumObservedSamples: Int
    let supportiveSampleCount: Int
    let minimumSupportiveSamples: Int
}

enum ScanPipelineCore {
    static func insertDistinct<T>(
        _ candidate: T,
        into list: inout [T],
        limit: Int,
        minimumSpacing: TimeInterval,
        time: (T) -> TimeInterval,
        distance: (T) -> Float
    ) {
        if let nearby = list.firstIndex(where: {
            abs(time($0) - time(candidate)) < minimumSpacing
        }) {
            guard distance(candidate) < distance(list[nearby]) else { return }
            list.remove(at: nearby)
        }

        if let position = list.firstIndex(where: {
            distance(candidate) < distance($0)
        }) {
            list.insert(candidate, at: position)
        } else {
            list.append(candidate)
        }

        let boundedLimit = max(1, limit)
        if list.count > boundedLimit {
            list.removeLast(list.count - boundedLimit)
        }
    }

    static func percentile(_ values: [Float], quantile: Double) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let q = min(1, max(0, quantile))
        let index = min(
            sorted.count - 1,
            Int((Double(sorted.count - 1) * q).rounded(.down))
        )
        return sorted[index]
    }

    static func detailThreshold(coarseThreshold: Float) -> Float {
        coarseThreshold + max(0.015, coarseThreshold * 0.08)
    }

    static func toleratedMissSpan(detailInterval: TimeInterval) -> TimeInterval {
        max(0.90, detailInterval * 5.0)
    }

    static func maximumContinuityBridgeSpan(detailInterval: TimeInterval) -> TimeInterval {
        let tolerated = toleratedMissSpan(detailInterval: detailInterval)
        return max(tolerated, min(2.25, tolerated + 1.0))
    }

    static func mergedDetailWindows(
        candidates: [ScanPipelinePoint],
        duration: TimeInterval,
        radius: TimeInterval
    ) -> [ScanPipelineTimeWindow] {
        let raw = candidates.map {
            ScanPipelineTimeWindow(
                start: max(0, $0.time - radius),
                end: min(duration, $0.time + radius)
            )
        }.sorted { $0.start < $1.start }

        guard var current = raw.first else { return [] }
        var merged: [ScanPipelineTimeWindow] = []

        for next in raw.dropFirst() {
            if next.start <= current.end + 0.5 {
                current.end = max(current.end, next.end)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    static func segmentPlans(
        hits: [ScanPipelinePoint],
        duration: TimeInterval,
        detailInterval: TimeInterval,
        observations: [ScanPipelineObservation] = [],
        hitThreshold: Float? = nil,
        confirmedContinuityWindows: [ScanPipelineTimeWindow] = []
    ) -> [ScanPipelineSegmentPlan] {
        guard !hits.isEmpty else { return [] }

        let toleratedMissSpan = toleratedMissSpan(detailInterval: detailInterval)
        let edgePadding = max(0.40, detailInterval * 1.5)
        let sortedObservations = observations.sorted { $0.time < $1.time }
        let diagnosticStage = confirmedContinuityWindows.isEmpty
            ? "preliminary"
            : "visual-confirmed-replay"

        var ranges: [Range<Int>] = []
        var groupStart = 0

        if hits.count > 1 {
            for index in 1..<hits.count {
                let gap = hits[index].time - hits[index - 1].time
                if gap > toleratedMissSpan {
                    let diagnostic = bridgeDiagnostic(
                        hits: hits,
                        splitIndex: index,
                        observations: sortedObservations,
                        hitThreshold: hitThreshold,
                        detailInterval: detailInterval,
                        toleratedMissSpan: toleratedMissSpan,
                        confirmedContinuityWindows: confirmedContinuityWindows
                    )
                    emitBridgeDiagnostic(diagnostic, stage: diagnosticStage)
                    if !diagnostic.shouldBridge {
                        ranges.append(groupStart..<index)
                        groupStart = index
                    }
                }
            }
        }
        ranges.append(groupStart..<hits.count)

        return ranges.map { range in
            let firstIndex = range.lowerBound
            let lastIndex = range.upperBound - 1
            var bestIndex = firstIndex

            for index in range.dropFirst() {
                if hits[index].distance < hits[bestIndex].distance {
                    bestIndex = index
                }
            }

            let observedSpan = max(
                detailInterval,
                hits[lastIndex].time - hits[firstIndex].time + detailInterval
            )
            let expectedSamples = max(
                1,
                Int((observedSpan / detailInterval).rounded(.up))
            )
            let trackingScore = min(
                1.0,
                Double(range.count) / Double(expectedSamples)
            )

            return ScanPipelineSegmentPlan(
                hitRange: range,
                bestHitIndex: bestIndex,
                startTime: max(0, hits[firstIndex].time - edgePadding),
                endTime: min(duration, hits[lastIndex].time + edgePadding),
                hitCount: range.count,
                trackingScore: trackingScore
            )
        }
    }

    static func bridgeDiagnostic(
        hits: [ScanPipelinePoint],
        splitIndex: Int,
        observations: [ScanPipelineObservation],
        hitThreshold: Float?,
        detailInterval: TimeInterval,
        toleratedMissSpan: TimeInterval? = nil,
        confirmedContinuityWindows: [ScanPipelineTimeWindow] = []
    ) -> ScanPipelineBridgeDiagnostic {
        let tolerated = toleratedMissSpan ?? self.toleratedMissSpan(detailInterval: detailInterval)
        let maximumBridgeSpan = maximumContinuityBridgeSpan(detailInterval: detailInterval)

        guard splitIndex > 0, splitIndex < hits.count else {
            return ScanPipelineBridgeDiagnostic(
                leftTime: 0,
                rightTime: 0,
                gap: 0,
                maximumBridgeSpan: maximumBridgeSpan,
                shouldBridge: false,
                reason: .missingObservations,
                leftFlankHitCount: 0,
                rightFlankHitCount: 0,
                interiorObservationCount: 0,
                minimumObservedSamples: 0,
                supportiveSampleCount: 0,
                minimumSupportiveSamples: 0
            )
        }

        let leftHit = hits[splitIndex - 1]
        let rightHit = hits[splitIndex]
        let gap = rightHit.time - leftHit.time

        func result(
            _ shouldBridge: Bool,
            _ reason: ScanPipelineBridgeReason,
            leftFlankHitCount: Int = 0,
            rightFlankHitCount: Int = 0,
            interiorObservationCount: Int = 0,
            minimumObservedSamples: Int = 0,
            supportiveSampleCount: Int = 0,
            minimumSupportiveSamples: Int = 0
        ) -> ScanPipelineBridgeDiagnostic {
            ScanPipelineBridgeDiagnostic(
                leftTime: leftHit.time,
                rightTime: rightHit.time,
                gap: gap,
                maximumBridgeSpan: maximumBridgeSpan,
                shouldBridge: shouldBridge,
                reason: reason,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount,
                interiorObservationCount: interiorObservationCount,
                minimumObservedSamples: minimumObservedSamples,
                supportiveSampleCount: supportiveSampleCount,
                minimumSupportiveSamples: minimumSupportiveSamples
            )
        }

        guard !observations.isEmpty else {
            return result(false, .missingObservations)
        }
        guard gap > tolerated, gap <= maximumBridgeSpan else {
            return result(false, .gapExceedsVisualBridgeLimit)
        }

        let flankWindow = max(0.75, detailInterval * 4.0)
        let leftFlankHitCount = hits[..<splitIndex].reduce(into: 0) { count, hit in
            if hit.time >= leftHit.time - flankWindow {
                count += 1
            }
        }
        let rightFlankHitCount = hits[splitIndex...].reduce(into: 0) { count, hit in
            if hit.time <= rightHit.time + flankWindow {
                count += 1
            }
        }
        guard leftFlankHitCount >= 2, rightFlankHitCount >= 2 else {
            return result(
                false,
                .insufficientFlankHits,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount
            )
        }

        let epsilon = max(0.001, detailInterval * 0.10)
        let interior = observations.filter {
            $0.time > leftHit.time + epsilon &&
            $0.time < rightHit.time - epsilon
        }
        guard !interior.isEmpty else {
            return result(
                false,
                .noInteriorObservations,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount
            )
        }

        let expectedInteriorSamples = max(
            1,
            Int((gap / detailInterval).rounded(.down)) - 1
        )
        let minimumObservedSamples = max(
            1,
            Int(ceil(Double(expectedInteriorSamples) * 0.60))
        )
        guard interior.count >= minimumObservedSamples else {
            return result(
                false,
                .insufficientObservationCoverage,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount,
                interiorObservationCount: interior.count,
                minimumObservedSamples: minimumObservedSamples
            )
        }

        guard !interior.contains(where: { $0.rejectedByNegative }) else {
            return result(
                false,
                .hardNegativeVeto,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount,
                interiorObservationCount: interior.count,
                minimumObservedSamples: minimumObservedSamples
            )
        }

        let continuityConfirmed = confirmedContinuityWindows.contains { window in
            window.start <= leftHit.time + epsilon &&
            window.end >= rightHit.time - epsilon
        }
        if continuityConfirmed {
            return result(
                true,
                .visualContinuityConfirmed,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount,
                interiorObservationCount: interior.count,
                minimumObservedSamples: minimumObservedSamples
            )
        }

        guard let hitThreshold else {
            return result(
                false,
                .missingHitThreshold,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount,
                interiorObservationCount: interior.count,
                minimumObservedSamples: minimumObservedSamples
            )
        }

        let bridgeEvidenceThreshold =
            hitThreshold + max(0.015, hitThreshold * 0.08)
        let supportiveSamples = interior.filter {
            !$0.isAcceptedHit &&
            !$0.rejectedByNegative &&
            $0.distance <= bridgeEvidenceThreshold
        }
        let minimumSupportiveSamples = max(
            1,
            Int(ceil(Double(interior.count) * 0.50))
        )
        guard supportiveSamples.count >= minimumSupportiveSamples else {
            return result(
                false,
                .insufficientWeakEvidence,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount,
                interiorObservationCount: interior.count,
                minimumObservedSamples: minimumObservedSamples,
                supportiveSampleCount: supportiveSamples.count,
                minimumSupportiveSamples: minimumSupportiveSamples
            )
        }

        let midpoint = (leftHit.time + rightHit.time) / 2.0
        let midpointWindow = max(0.35, detailInterval * 1.5)
        let hasMidpointEvidence = supportiveSamples.contains {
            abs($0.time - midpoint) <= midpointWindow
        }
        guard hasMidpointEvidence else {
            return result(
                false,
                .midpointEvidenceMissing,
                leftFlankHitCount: leftFlankHitCount,
                rightFlankHitCount: rightFlankHitCount,
                interiorObservationCount: interior.count,
                minimumObservedSamples: minimumObservedSamples,
                supportiveSampleCount: supportiveSamples.count,
                minimumSupportiveSamples: minimumSupportiveSamples
            )
        }

        return result(
            true,
            .weakEvidenceConfirmed,
            leftFlankHitCount: leftFlankHitCount,
            rightFlankHitCount: rightFlankHitCount,
            interiorObservationCount: interior.count,
            minimumObservedSamples: minimumObservedSamples,
            supportiveSampleCount: supportiveSamples.count,
            minimumSupportiveSamples: minimumSupportiveSamples
        )
    }

    private static func emitBridgeDiagnostic(
        _ diagnostic: ScanPipelineBridgeDiagnostic,
        stage: String
    ) {
        #if canImport(UIKit)
        let decision = diagnostic.shouldBridge ? "bridge" : "split"
        let message = String(
            format: "Segment bridge diagnostic: stage=%@ %.3f -> %.3f gap=%.3fs max=%.3fs decision=%@ reason=%@ flank=%d/%d interior=%d(min=%d) supportive=%d(min=%d)",
            stage,
            diagnostic.leftTime,
            diagnostic.rightTime,
            diagnostic.gap,
            diagnostic.maximumBridgeSpan,
            decision,
            diagnostic.reason.rawValue,
            diagnostic.leftFlankHitCount,
            diagnostic.rightFlankHitCount,
            diagnostic.interiorObservationCount,
            diagnostic.minimumObservedSamples,
            diagnostic.supportiveSampleCount,
            diagnostic.minimumSupportiveSamples
        )
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                DiagnosticLogger.log(message)
            }
        } else {
            Task { @MainActor in
                DiagnosticLogger.log(message)
            }
        }
        #endif
    }
}
