import CoreGraphics
import Foundation

@main
enum SegmentVisualContinuityDiagnosticTests {
    static func output(
        _ rect: CGRect?,
        confidence: Float? = 0.80,
        failed: Bool = false
    ) -> VisionTrackingFrameOutput {
        VisionTrackingFrameOutput(
            boundingBox: rect,
            confidence: confidence,
            requestFailed: failed
        )
    }

    static func main() {
        let forward = [
            output(CGRect(x: 0.30, y: 0.27, width: 0.36, height: 0.46), confidence: 0.82),
            output(CGRect(x: 0.32, y: 0.27, width: 0.36, height: 0.46), confidence: 0.78),
            output(CGRect(x: 0.34, y: 0.27, width: 0.36, height: 0.46), confidence: 0.75)
        ]
        let backward = [
            output(CGRect(x: 0.39, y: 0.27, width: 0.36, height: 0.46), confidence: 0.80),
            output(CGRect(x: 0.37, y: 0.27, width: 0.36, height: 0.46), confidence: 0.77),
            output(CGRect(x: 0.35, y: 0.27, width: 0.36, height: 0.46), confidence: 0.74)
        ]
        let midpoint = CGRect(x: 0.345, y: 0.27, width: 0.36, height: 0.46)

        let confirmed = SegmentContinuityAnalyzer.evaluate(
            forward: forward,
            backward: backward,
            midpointReferenceRect: midpoint
        )
        precondition(confirmed.shouldBridge)
        precondition(confirmed.reason == .confirmed)

        var trackingLost = forward
        trackingLost[1] = output(nil)
        let lost = SegmentContinuityAnalyzer.evaluate(
            forward: trackingLost,
            backward: backward,
            midpointReferenceRect: midpoint
        )
        precondition(!lost.shouldBridge)
        precondition(lost.reason == .trackingLostOrFailed)

        let lowConfidence = forward.map {
            output($0.boundingBox, confidence: 0.20)
        }
        let weak = SegmentContinuityAnalyzer.evaluate(
            forward: lowConfidence,
            backward: backward,
            midpointReferenceRect: midpoint
        )
        precondition(!weak.shouldBridge)
        precondition(weak.reason == .insufficientTrackingConfidence)

        let divergedBackward = [
            output(CGRect(x: 0.75, y: 0.08, width: 0.16, height: 0.20), confidence: 0.80),
            output(CGRect(x: 0.77, y: 0.08, width: 0.16, height: 0.20), confidence: 0.78)
        ]
        let diverged = SegmentContinuityAnalyzer.evaluate(
            forward: forward,
            backward: divergedBackward,
            midpointReferenceRect: midpoint
        )
        precondition(!diverged.shouldBridge)
        precondition(diverged.reason == .trackersDisagree)

        let noMidpoint = SegmentContinuityAnalyzer.evaluate(
            forward: forward,
            backward: backward,
            midpointReferenceRect: nil
        )
        precondition(!noMidpoint.shouldBridge)
        precondition(noMidpoint.reason == .missingMidpointReference)

        print("Segment visual continuity diagnostic reason tests: PASS")
    }
}
