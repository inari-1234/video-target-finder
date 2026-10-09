import Foundation

@main
enum DIAG2RescanMergeTests {
    static func main() {
        let existing = [
            SegmentFeedbackMergeDescriptor(
                startTime: 619.550,
                endTime: 620.350,
                discoverySource: "initial",
                hitCount: 1,
                trackingScore: 1.0
            ),
            SegmentFeedbackMergeDescriptor(
                startTime: 622.838,
                endTime: 625.377,
                discoverySource: "initial",
                hitCount: 5,
                trackingScore: 0.45
            )
        ]

        let spanning = SegmentFeedbackMergeDescriptor(
            startTime: 619.400,
            endTime: 625.500,
            discoverySource: "feedback-rescan",
            hitCount: 18,
            trackingScore: 0.74
        )
        let spanningDiagnostic = SegmentFeedbackMergeDiagnosticAnalyzer.evaluate(
            candidate: spanning,
            existing: existing,
            overlapTolerance: 0.45
        )
        precondition(spanningDiagnostic.isDiscardedByCurrentBehavior)
        precondition(spanningDiagnostic.spansMultipleExistingSegments)
        precondition(spanningDiagnostic.overlaps.count == 2)
        precondition(spanningDiagnostic.overlaps.allSatisfy { $0.overlapAmount > 0 })

        let oneOverlap = SegmentFeedbackMergeDescriptor(
            startTime: 622.900,
            endTime: 624.000,
            discoverySource: "feedback-rescan",
            hitCount: 4,
            trackingScore: 0.52
        )
        let oneDiagnostic = SegmentFeedbackMergeDiagnosticAnalyzer.evaluate(
            candidate: oneOverlap,
            existing: existing,
            overlapTolerance: 0.45
        )
        precondition(oneDiagnostic.isDiscardedByCurrentBehavior)
        precondition(!oneDiagnostic.spansMultipleExistingSegments)
        precondition(oneDiagnostic.overlaps.count == 1)

        let separate = SegmentFeedbackMergeDescriptor(
            startTime: 630.000,
            endTime: 631.000,
            discoverySource: "feedback-rescan",
            hitCount: 3,
            trackingScore: 0.60
        )
        let separateDiagnostic = SegmentFeedbackMergeDiagnosticAnalyzer.evaluate(
            candidate: separate,
            existing: existing,
            overlapTolerance: 0.45
        )
        precondition(!separateDiagnostic.isDiscardedByCurrentBehavior)
        precondition(separateDiagnostic.overlaps.isEmpty)

        print("DIAG-2 feedback rescan merge regression: PASS")
    }
}
