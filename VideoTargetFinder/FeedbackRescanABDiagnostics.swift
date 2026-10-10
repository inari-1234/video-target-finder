import Foundation

struct FeedbackReviewReplaySegment: Sendable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let reviewStateRawValue: String?
}

struct FeedbackReviewReplayTemplate: Sendable, Equatable {
    let videoAssetIdentifier: String
    let segments: [FeedbackReviewReplaySegment]
}

enum FeedbackReviewReplayError: String, Error, Sendable, Equatable {
    case videoMismatch = "video-mismatch"
    case segmentCountMismatch = "segment-count-mismatch"
    case segmentGeometryMismatch = "segment-geometry-mismatch"
}

struct FeedbackReviewReplayMatch: Sendable, Equatable {
    let assignments: [UUID: String]
    let reviewedCount: Int
}

enum FeedbackReviewReplayMatcher {
    static let defaultBoundaryTolerance: TimeInterval = 0.30

    static func makeTemplate(
        videoAssetIdentifier: String,
        segments: [FeedbackReviewReplaySegment]
    ) -> FeedbackReviewReplayTemplate {
        FeedbackReviewReplayTemplate(
            videoAssetIdentifier: videoAssetIdentifier,
            segments: sorted(segments)
        )
    }

    static func match(
        template: FeedbackReviewReplayTemplate,
        currentVideoAssetIdentifier: String,
        currentSegments: [FeedbackReviewReplaySegment],
        boundaryTolerance: TimeInterval = defaultBoundaryTolerance
    ) -> Result<FeedbackReviewReplayMatch, FeedbackReviewReplayError> {
        guard template.videoAssetIdentifier == currentVideoAssetIdentifier else {
            return .failure(.videoMismatch)
        }

        let expected = sorted(template.segments)
        let current = sorted(currentSegments)
        guard expected.count == current.count else {
            return .failure(.segmentCountMismatch)
        }

        var assignments: [UUID: String] = [:]
        for (lhs, rhs) in zip(expected, current) {
            guard abs(lhs.startTime - rhs.startTime) <= boundaryTolerance,
                  abs(lhs.endTime - rhs.endTime) <= boundaryTolerance else {
                return .failure(.segmentGeometryMismatch)
            }
            if let state = lhs.reviewStateRawValue {
                assignments[rhs.id] = state
            }
        }

        return .success(
            FeedbackReviewReplayMatch(
                assignments: assignments,
                reviewedCount: assignments.count
            )
        )
    }

    static func reviewLogString(_ segments: [FeedbackReviewReplaySegment]) -> String {
        let reviewed = sorted(segments).compactMap { segment -> String? in
            guard let state = segment.reviewStateRawValue else { return nil }
            return String(
                format: "%.3f-%.3f=%@",
                segment.startTime,
                segment.endTime,
                state
            )
        }
        return reviewed.isEmpty ? "none" : reviewed.joined(separator: ";")
    }

    private static func sorted(_ segments: [FeedbackReviewReplaySegment]) -> [FeedbackReviewReplaySegment] {
        segments.sorted {
            if abs($0.startTime - $1.startTime) > 0.000_001 {
                return $0.startTime < $1.startTime
            }
            if abs($0.endTime - $1.endTime) > 0.000_001 {
                return $0.endTime < $1.endTime
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
