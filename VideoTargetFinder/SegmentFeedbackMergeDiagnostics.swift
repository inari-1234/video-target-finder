import Foundation

struct SegmentFeedbackMergeDescriptor: Sendable, Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let discoverySource: String
    let hitCount: Int
    let trackingScore: Double
}

struct SegmentFeedbackMergeOverlap: Sendable, Equatable {
    let existingIndex: Int
    let existingStartTime: TimeInterval
    let existingEndTime: TimeInterval
    let existingDiscoverySource: String
    let overlapAmount: TimeInterval
    let toleranceAdjustedOverlapAmount: TimeInterval
}

struct SegmentFeedbackMergeDiagnostic: Sendable, Equatable {
    let candidate: SegmentFeedbackMergeDescriptor
    let overlapTolerance: TimeInterval
    let overlaps: [SegmentFeedbackMergeOverlap]
    let isDiscardedByCurrentBehavior: Bool
    let spansMultipleExistingSegments: Bool
}

enum SegmentFeedbackMergeDiagnosticAnalyzer {
    static func evaluate(
        candidate: SegmentFeedbackMergeDescriptor,
        existing: [SegmentFeedbackMergeDescriptor],
        overlapTolerance: TimeInterval
    ) -> SegmentFeedbackMergeDiagnostic {
        let overlaps = existing.enumerated().compactMap { index, current -> SegmentFeedbackMergeOverlap? in
            let overlapsWithTolerance =
                candidate.startTime <= current.endTime + overlapTolerance &&
                candidate.endTime >= current.startTime - overlapTolerance
            guard overlapsWithTolerance else { return nil }

            let actualOverlap = max(
                0,
                min(candidate.endTime, current.endTime) -
                max(candidate.startTime, current.startTime)
            )
            let toleranceAdjustedOverlap = max(
                0,
                min(candidate.endTime + overlapTolerance, current.endTime + overlapTolerance) -
                max(candidate.startTime - overlapTolerance, current.startTime - overlapTolerance)
            )
            return SegmentFeedbackMergeOverlap(
                existingIndex: index,
                existingStartTime: current.startTime,
                existingEndTime: current.endTime,
                existingDiscoverySource: current.discoverySource,
                overlapAmount: actualOverlap,
                toleranceAdjustedOverlapAmount: toleranceAdjustedOverlap
            )
        }

        return SegmentFeedbackMergeDiagnostic(
            candidate: candidate,
            overlapTolerance: overlapTolerance,
            overlaps: overlaps,
            isDiscardedByCurrentBehavior: !overlaps.isEmpty,
            spansMultipleExistingSegments: overlaps.count >= 2
        )
    }
}
