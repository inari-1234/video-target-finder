import Foundation

@main
enum SegmentBridgeDiagnosticTests {
    static func main() {
        let hits = [
            ScanPipelinePoint(time: 0.00, distance: 0.20),
            ScanPipelinePoint(time: 0.25, distance: 0.19),
            ScanPipelinePoint(time: 0.50, distance: 0.21),
            ScanPipelinePoint(time: 0.75, distance: 0.20),
            ScanPipelinePoint(time: 1.00, distance: 0.22),
            ScanPipelinePoint(time: 3.00, distance: 0.21),
            ScanPipelinePoint(time: 3.25, distance: 0.20),
            ScanPipelinePoint(time: 3.50, distance: 0.19),
            ScanPipelinePoint(time: 3.75, distance: 0.20),
            ScanPipelinePoint(time: 4.00, distance: 0.21)
        ]
        let weakEvidence = stride(from: 1.25, through: 2.75, by: 0.25).map {
            ScanPipelineObservation(
                time: $0,
                distance: 0.312,
                rejectedByNegative: false,
                isAcceptedHit: false
            )
        }
        let weak = ScanPipelineCore.bridgeDiagnostic(
            hits: hits,
            splitIndex: 5,
            observations: weakEvidence,
            hitThreshold: 0.30,
            detailInterval: 0.25
        )
        precondition(weak.shouldBridge)
        precondition(weak.reason == .weakEvidenceConfirmed)

        let fullDropout = stride(from: 1.25, through: 2.75, by: 0.25).map {
            ScanPipelineObservation(
                time: $0,
                distance: 0.60,
                rejectedByNegative: false,
                isAcceptedHit: false
            )
        }
        let dropout = ScanPipelineCore.bridgeDiagnostic(
            hits: hits,
            splitIndex: 5,
            observations: fullDropout,
            hitThreshold: 0.30,
            detailInterval: 0.25
        )
        precondition(!dropout.shouldBridge)
        precondition(dropout.reason == .insufficientWeakEvidence)

        let visuallyConfirmed = ScanPipelineCore.bridgeDiagnostic(
            hits: hits,
            splitIndex: 5,
            observations: fullDropout,
            hitThreshold: 0.30,
            detailInterval: 0.25,
            confirmedContinuityWindows: [
                ScanPipelineTimeWindow(start: 1.00, end: 3.00)
            ]
        )
        precondition(visuallyConfirmed.shouldBridge)
        precondition(visuallyConfirmed.reason == .visualContinuityConfirmed)

        var hardNegative = fullDropout
        hardNegative[2] = ScanPipelineObservation(
            time: hardNegative[2].time,
            distance: hardNegative[2].distance,
            rejectedByNegative: true,
            isAcceptedHit: false
        )
        let negative = ScanPipelineCore.bridgeDiagnostic(
            hits: hits,
            splitIndex: 5,
            observations: hardNegative,
            hitThreshold: 0.30,
            detailInterval: 0.25,
            confirmedContinuityWindows: [
                ScanPipelineTimeWindow(start: 1.00, end: 3.00)
            ]
        )
        precondition(!negative.shouldBridge)
        precondition(negative.reason == .hardNegativeVeto)

        // Mirrors the suspected real-device split: the raw hit-to-hit gap is
        // about 2.49 s, which is larger than the current 2.25 s visual bridge ceiling.
        let overLimitHits = [
            ScanPipelinePoint(time: 0.00, distance: 0.20),
            ScanPipelinePoint(time: 0.25, distance: 0.19),
            ScanPipelinePoint(time: 0.50, distance: 0.21),
            ScanPipelinePoint(time: 0.75, distance: 0.20),
            ScanPipelinePoint(time: 1.00, distance: 0.22),
            ScanPipelinePoint(time: 3.49, distance: 0.21),
            ScanPipelinePoint(time: 3.74, distance: 0.20),
            ScanPipelinePoint(time: 3.99, distance: 0.19)
        ]
        let overLimitObservations = stride(from: 1.25, through: 3.25, by: 0.25).map {
            ScanPipelineObservation(
                time: $0,
                distance: 0.60,
                rejectedByNegative: false,
                isAcceptedHit: false
            )
        }
        let overLimit = ScanPipelineCore.bridgeDiagnostic(
            hits: overLimitHits,
            splitIndex: 5,
            observations: overLimitObservations,
            hitThreshold: 0.30,
            detailInterval: 0.25
        )
        precondition(!overLimit.shouldBridge)
        precondition(overLimit.reason == .gapExceedsVisualBridgeLimit)
        precondition(abs(overLimit.gap - 2.49) < 0.0001)
        precondition(abs(overLimit.maximumBridgeSpan - 2.25) < 0.0001)

        print("Segment bridge diagnostic reason tests: PASS")
    }
}
