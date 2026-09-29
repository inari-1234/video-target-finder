import CoreGraphics
import Foundation

@main
enum ObjectTrackingDiagnosticsTests {
    static func approx(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= tolerance
    }

    static func sample(
        _ direction: ObjectTrackingDirection,
        _ offset: Double,
        tracked: CGRect?,
        confidence: Float?,
        reference: CGRect?
    ) -> ObjectTrackingFrameDiagnostic {
        ObjectTrackingFrameDiagnostic(
            direction: direction,
            offsetSeconds: offset,
            trackedRect: tracked,
            confidence: confidence,
            referenceRect: reference
        )
    }

    static func main() {
        let padded = ObjectTrackingDiagnosticAnalyzer.paddedSeedRect(
            CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.4)
        )
        precondition(abs(Double(padded.minX) - 0.18) < 0.0001)
        precondition(abs(Double(padded.width) - 0.24) < 0.0001)

        let reference = CGRect(x: 0.20, y: 0.20, width: 0.20, height: 0.30)
        let close = CGRect(x: 0.21, y: 0.21, width: 0.20, height: 0.30)
        let far = CGRect(x: 0.65, y: 0.65, width: 0.15, height: 0.20)

        let candidate = ObjectTrackingCandidateDiagnostic(
            segmentID: UUID(),
            seedRect: reference,
            variants: [
                ObjectTrackingVariantDiagnostic(
                    variant: .tight,
                    samples: [
                        sample(.forward, 0.125, tracked: close, confidence: 0.9, reference: reference),
                        sample(.forward, 0.250, tracked: close, confidence: 0.8, reference: reference),
                        sample(.backward, -0.125, tracked: nil, confidence: nil, reference: reference)
                    ]
                ),
                ObjectTrackingVariantDiagnostic(
                    variant: .padded,
                    samples: [
                        sample(.forward, 0.125, tracked: far, confidence: 0.7, reference: reference),
                        sample(.forward, 0.250, tracked: far, confidence: 0.6, reference: reference),
                        sample(.backward, -0.125, tracked: close, confidence: 0.85, reference: reference)
                    ]
                )
            ]
        )

        guard let summary = ObjectTrackingDiagnosticAnalyzer.benchmark(
            candidates: [candidate],
            elapsedSeconds: 5,
            wasThermallyLimited: false,
            seedFailureCount: 1,
            referenceDetectionFailureCount: 2,
            frameLoadFailureCount: 3
        ) else {
            fatalError("summary missing")
        }

        precondition(summary.candidateCount == 2)
        precondition(summary.seededCandidateCount == 1)
        precondition(summary.tight.attemptedFrameCount == 3)
        precondition(summary.tight.trackedFrameCount == 2)
        precondition(summary.tight.referenceAgreementFrameCount == 2)
        precondition(summary.tight.directionLossCount == 1)
        precondition(approx(summary.tight.continuationRate, 2.0 / 3.0))
        precondition(approx(summary.tight.referenceAgreementRate, 1.0))
        precondition(summary.padded.referenceAgreementFrameCount == 1)
        precondition(summary.padded.directionLossCount == 0)
        precondition(summary.referenceDetectionFailureCount == 2)
        precondition(summary.frameLoadFailureCount == 3)

        print("ObjectTrackingDiagnostics tests: PASS")
    }
}
