import Foundation

enum SegmentBridgeShadowReason: String, Sendable, Equatable {
    case notSplitCandidate = "not-split-candidate"
    case missingObservations = "missing-observations"
    case gapExceedsShadowHorizon = "gap-exceeds-shadow-horizon"
    case insufficientFlankHits = "insufficient-flank-hits"
    case noInteriorObservations = "no-interior-observations"
    case insufficientObservationCoverage = "insufficient-observation-coverage"
    case hardNegativeVeto = "hard-negative-veto"
    case missingHitThreshold = "missing-hit-threshold"
    case visualContinuityPending = "visual-continuity-pending"
    case visualContinuityFailed = "visual-continuity-failed"
    case insufficientWeakEvidence = "insufficient-weak-evidence"
    case midpointEvidenceMissing = "midpoint-evidence-missing"
    case visualContinuityConfirmed = "visual-continuity-confirmed"
    case weakEvidenceConfirmed = "weak-evidence-confirmed"
}

struct SegmentBridgeShadowDiagnostic: Sendable, Equatable {
    let leftAcceptedHitTime: TimeInterval
    let rightAcceptedHitTime: TimeInterval
    let acceptedHitGap: TimeInterval
    let segmentBoundaryGap: TimeInterval
    let productionMaximumBridgeSpan: TimeInterval
    let shadowHorizon: TimeInterval
    let productionShouldBridge: Bool
    let productionReason: ScanPipelineBridgeReason
    let shadowShouldBridge: Bool
    let shadowReason: SegmentBridgeShadowReason
    let leftFlankHitCount: Int
    let rightFlankHitCount: Int
    let interiorObservationCount: Int
    let expectedObservationCount: Int
    let minimumRequiredObservationCount: Int
    let interiorDistanceMinimum: Float?
    let interiorDistanceMaximum: Float?
    let interiorDistanceMean: Double?
    let weakSupportCount: Int
    let weakSupportRatio: Double
    let hardNegativeTimes: [TimeInterval]
    let visualContinuityPassed: Bool?
}

enum SegmentBridgeShadowAnalyzer {
    static let defaultShadowHorizon: TimeInterval = 6.0

    static func evaluate(
        hits: [ScanPipelinePoint],
        splitIndex: Int,
        observations: [ScanPipelineObservation],
        hitThreshold: Float?,
        detailInterval: TimeInterval,
        edgePadding: TimeInterval? = nil,
        shadowHorizon: TimeInterval = defaultShadowHorizon,
        visualContinuityPassed: Bool? = nil
    ) -> SegmentBridgeShadowDiagnostic {
        let productionMaximum = ScanPipelineCore.maximumContinuityBridgeSpan(
            detailInterval: detailInterval
        )
        let boundedEdgePadding = edgePadding ?? max(0.40, detailInterval * 1.5)

        guard splitIndex > 0, splitIndex < hits.count else {
            return SegmentBridgeShadowDiagnostic(
                leftAcceptedHitTime: 0,
                rightAcceptedHitTime: 0,
                acceptedHitGap: 0,
                segmentBoundaryGap: 0,
                productionMaximumBridgeSpan: productionMaximum,
                shadowHorizon: shadowHorizon,
                productionShouldBridge: false,
                productionReason: .missingObservations,
                shadowShouldBridge: false,
                shadowReason: .notSplitCandidate,
                leftFlankHitCount: 0,
                rightFlankHitCount: 0,
                interiorObservationCount: 0,
                expectedObservationCount: 0,
                minimumRequiredObservationCount: 0,
                interiorDistanceMinimum: nil,
                interiorDistanceMaximum: nil,
                interiorDistanceMean: nil,
                weakSupportCount: 0,
                weakSupportRatio: 0,
                hardNegativeTimes: [],
                visualContinuityPassed: visualContinuityPassed
            )
        }

        let leftHit = hits[splitIndex - 1]
        let rightHit = hits[splitIndex]
        let acceptedHitGap = rightHit.time - leftHit.time
        let tolerated = ScanPipelineCore.toleratedMissSpan(detailInterval: detailInterval)
        let epsilon = max(0.001, detailInterval * 0.10)
        let flankWindow = max(0.75, detailInterval * 4.0)
        let leftFlankHitCount = hits[..<splitIndex].reduce(into: 0) { count, hit in
            if hit.time >= leftHit.time - flankWindow { count += 1 }
        }
        let rightFlankHitCount = hits[splitIndex...].reduce(into: 0) { count, hit in
            if hit.time <= rightHit.time + flankWindow { count += 1 }
        }
        let interior = observations.filter {
            $0.time > leftHit.time + epsilon &&
            $0.time < rightHit.time - epsilon
        }
        let expectedObservationCount = max(
            1,
            Int((acceptedHitGap / detailInterval).rounded(.down)) - 1
        )
        let minimumRequiredObservationCount = max(
            1,
            Int(ceil(Double(expectedObservationCount) * 0.60))
        )
        let distances = interior.map(\.distance)
        let distanceMinimum = distances.min()
        let distanceMaximum = distances.max()
        let distanceMean = distances.isEmpty
            ? nil
            : distances.reduce(0.0) { $0 + Double($1) } / Double(distances.count)
        let hardNegativeTimes = interior
            .filter(\.rejectedByNegative)
            .map(\.time)
        let bridgeEvidenceThreshold = hitThreshold.map {
            $0 + max(0.015, $0 * 0.08)
        }
        let weakSupport = interior.filter { observation in
            guard let bridgeEvidenceThreshold else { return false }
            return !observation.isAcceptedHit &&
                !observation.rejectedByNegative &&
                observation.distance <= bridgeEvidenceThreshold
        }
        let weakSupportRatio = interior.isEmpty
            ? 0
            : Double(weakSupport.count) / Double(interior.count)
        let minimumWeakSupportCount = max(
            1,
            Int(ceil(Double(interior.count) * 0.50))
        )
        let midpoint = (leftHit.time + rightHit.time) / 2.0
        let midpointWindow = max(0.35, detailInterval * 1.5)
        let hasMidpointWeakEvidence = weakSupport.contains {
            abs($0.time - midpoint) <= midpointWindow
        }

        let confirmedContinuityWindows: [ScanPipelineTimeWindow]
        if visualContinuityPassed == true {
            confirmedContinuityWindows = [
                ScanPipelineTimeWindow(start: leftHit.time, end: rightHit.time)
            ]
        } else {
            confirmedContinuityWindows = []
        }
        let production = ScanPipelineCore.bridgeDiagnostic(
            hits: hits,
            splitIndex: splitIndex,
            observations: observations,
            hitThreshold: hitThreshold,
            detailInterval: detailInterval,
            confirmedContinuityWindows: confirmedContinuityWindows
        )

        let shadowDecision: (Bool, SegmentBridgeShadowReason)
        if acceptedHitGap <= tolerated {
            shadowDecision = (false, .notSplitCandidate)
        } else if observations.isEmpty {
            shadowDecision = (false, .missingObservations)
        } else if acceptedHitGap > shadowHorizon {
            shadowDecision = (false, .gapExceedsShadowHorizon)
        } else if leftFlankHitCount < 2 || rightFlankHitCount < 2 {
            shadowDecision = (false, .insufficientFlankHits)
        } else if interior.isEmpty {
            shadowDecision = (false, .noInteriorObservations)
        } else if interior.count < minimumRequiredObservationCount {
            shadowDecision = (false, .insufficientObservationCoverage)
        } else if !hardNegativeTimes.isEmpty {
            shadowDecision = (false, .hardNegativeVeto)
        } else if visualContinuityPassed == true {
            shadowDecision = (true, .visualContinuityConfirmed)
        } else if hitThreshold == nil {
            shadowDecision = (false, .missingHitThreshold)
        } else if weakSupport.count >= minimumWeakSupportCount && hasMidpointWeakEvidence {
            shadowDecision = (true, .weakEvidenceConfirmed)
        } else if visualContinuityPassed == false {
            shadowDecision = (false, .visualContinuityFailed)
        } else if weakSupport.count < minimumWeakSupportCount {
            shadowDecision = (false, .visualContinuityPending)
        } else {
            shadowDecision = (false, .midpointEvidenceMissing)
        }

        return SegmentBridgeShadowDiagnostic(
            leftAcceptedHitTime: leftHit.time,
            rightAcceptedHitTime: rightHit.time,
            acceptedHitGap: acceptedHitGap,
            segmentBoundaryGap: max(
                0,
                (rightHit.time - boundedEdgePadding) -
                (leftHit.time + boundedEdgePadding)
            ),
            productionMaximumBridgeSpan: productionMaximum,
            shadowHorizon: shadowHorizon,
            productionShouldBridge: production.shouldBridge,
            productionReason: production.reason,
            shadowShouldBridge: shadowDecision.0,
            shadowReason: shadowDecision.1,
            leftFlankHitCount: leftFlankHitCount,
            rightFlankHitCount: rightFlankHitCount,
            interiorObservationCount: interior.count,
            expectedObservationCount: expectedObservationCount,
            minimumRequiredObservationCount: minimumRequiredObservationCount,
            interiorDistanceMinimum: distanceMinimum,
            interiorDistanceMaximum: distanceMaximum,
            interiorDistanceMean: distanceMean,
            weakSupportCount: weakSupport.count,
            weakSupportRatio: weakSupportRatio,
            hardNegativeTimes: hardNegativeTimes,
            visualContinuityPassed: visualContinuityPassed
        )
    }
}
