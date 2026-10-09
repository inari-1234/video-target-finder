import Foundation

@main
enum DIAG2ShadowBridgeTests {
    static func observations(
        from start: Double,
        through end: Double,
        step: Double = 0.25,
        distance: Float = 0.60
    ) -> [ScanPipelineObservation] {
        stride(from: start, through: end, by: step).map {
            ScanPipelineObservation(
                time: $0,
                distance: distance,
                rejectedByNegative: false,
                isAcceptedHit: false
            )
        }
    }

    static func main() {
        let hits329 = [
            ScanPipelinePoint(time: 0.00, distance: 0.20),
            ScanPipelinePoint(time: 0.25, distance: 0.19),
            ScanPipelinePoint(time: 0.50, distance: 0.21),
            ScanPipelinePoint(time: 0.75, distance: 0.20),
            ScanPipelinePoint(time: 1.00, distance: 0.22),
            ScanPipelinePoint(time: 4.29, distance: 0.21),
            ScanPipelinePoint(time: 4.54, distance: 0.20),
            ScanPipelinePoint(time: 4.79, distance: 0.19),
            ScanPipelinePoint(time: 5.04, distance: 0.20)
        ]
        let dropout329 = observations(from: 1.25, through: 4.00)
        let shadow329 = SegmentBridgeShadowAnalyzer.evaluate(
            hits: hits329,
            splitIndex: 5,
            observations: dropout329,
            hitThreshold: 0.30,
            detailInterval: 0.25,
            visualContinuityPassed: true
        )
        precondition(!shadow329.productionShouldBridge)
        precondition(shadow329.productionReason == .gapExceedsVisualBridgeLimit)
        precondition(shadow329.shadowShouldBridge)
        precondition(shadow329.shadowReason == .visualContinuityConfirmed)
        precondition(abs(shadow329.acceptedHitGap - 3.29) < 0.0001)
        precondition(abs(shadow329.segmentBoundaryGap - 2.49) < 0.0001)
        precondition(shadow329.leftFlankHitCount >= 2)
        precondition(shadow329.rightFlankHitCount >= 2)
        precondition(shadow329.interiorObservationCount >= shadow329.minimumRequiredObservationCount)

        let oneHitLeft = [
            ScanPipelinePoint(time: 0.00, distance: 0.20),
            ScanPipelinePoint(time: 2.00, distance: 0.20),
            ScanPipelinePoint(time: 5.29, distance: 0.21),
            ScanPipelinePoint(time: 5.54, distance: 0.20),
            ScanPipelinePoint(time: 5.79, distance: 0.19),
            ScanPipelinePoint(time: 6.04, distance: 0.20)
        ]
        let oneHitObservations = observations(from: 2.25, through: 5.00)
        let oneHit = SegmentBridgeShadowAnalyzer.evaluate(
            hits: oneHitLeft,
            splitIndex: 2,
            observations: oneHitObservations,
            hitThreshold: 0.30,
            detailInterval: 0.25,
            visualContinuityPassed: true
        )
        precondition(!oneHit.productionShouldBridge)
        precondition(oneHit.productionReason == .gapExceedsVisualBridgeLimit)
        precondition(!oneHit.shadowShouldBridge)
        precondition(oneHit.shadowReason == .insufficientFlankHits)
        precondition(oneHit.leftFlankHitCount == 1)
        precondition(oneHit.visualContinuityPassed == true)

        let ceilingHits = [
            ScanPipelinePoint(time: 0.00, distance: 0.20),
            ScanPipelinePoint(time: 0.25, distance: 0.19),
            ScanPipelinePoint(time: 0.50, distance: 0.21),
            ScanPipelinePoint(time: 0.75, distance: 0.20),
            ScanPipelinePoint(time: 1.00, distance: 0.22),
            ScanPipelinePoint(time: 3.25, distance: 0.21),
            ScanPipelinePoint(time: 3.50, distance: 0.20),
            ScanPipelinePoint(time: 3.75, distance: 0.19),
            ScanPipelinePoint(time: 4.00, distance: 0.20)
        ]
        let ceilingCopy = ceilingHits
        let ceiling = SegmentBridgeShadowAnalyzer.evaluate(
            hits: ceilingHits,
            splitIndex: 5,
            observations: observations(from: 1.25, through: 3.00),
            hitThreshold: 0.30,
            detailInterval: 0.25,
            visualContinuityPassed: true
        )
        precondition(ceiling.shadowShouldBridge)
        precondition(ceiling.shadowReason == .visualContinuityConfirmed)
        precondition(ceilingHits == ceilingCopy)

        var hardNegativeObservations = dropout329
        hardNegativeObservations[3] = ScanPipelineObservation(
            time: hardNegativeObservations[3].time,
            distance: hardNegativeObservations[3].distance,
            rejectedByNegative: true,
            isAcceptedHit: false
        )
        let hardNegative = SegmentBridgeShadowAnalyzer.evaluate(
            hits: hits329,
            splitIndex: 5,
            observations: hardNegativeObservations,
            hitThreshold: 0.30,
            detailInterval: 0.25,
            visualContinuityPassed: true
        )
        precondition(!hardNegative.productionShouldBridge)
        precondition(!hardNegative.shadowShouldBridge)
        precondition(hardNegative.shadowReason == .hardNegativeVeto)
        precondition(hardNegative.hardNegativeTimes.count == 1)

        let overShadow = [
            ScanPipelinePoint(time: 0.00, distance: 0.20),
            ScanPipelinePoint(time: 0.25, distance: 0.19),
            ScanPipelinePoint(time: 0.50, distance: 0.21),
            ScanPipelinePoint(time: 0.75, distance: 0.20),
            ScanPipelinePoint(time: 1.00, distance: 0.22),
            ScanPipelinePoint(time: 7.25, distance: 0.21),
            ScanPipelinePoint(time: 7.50, distance: 0.20)
        ]
        let beyond = SegmentBridgeShadowAnalyzer.evaluate(
            hits: overShadow,
            splitIndex: 5,
            observations: observations(from: 1.25, through: 7.00),
            hitThreshold: 0.30,
            detailInterval: 0.25,
            visualContinuityPassed: true
        )
        precondition(!beyond.shadowShouldBridge)
        precondition(beyond.shadowReason == .gapExceedsShadowHorizon)

        print("DIAG-2 shadow bridge regression: PASS")
    }
}
