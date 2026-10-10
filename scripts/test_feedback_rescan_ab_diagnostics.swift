import Foundation

@main
struct FeedbackRescanABDiagnosticsTests {
    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let a = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
        let template = FeedbackReviewReplayMatcher.makeTemplate(
            videoAssetIdentifier: "video-1",
            segments: [
                FeedbackReviewReplaySegment(id: a, startTime: 10.0, endTime: 12.0, reviewStateRawValue: "正解"),
                FeedbackReviewReplaySegment(id: b, startTime: 20.0, endTime: 21.0, reviewStateRawValue: "誤検出"),
                FeedbackReviewReplaySegment(id: c, startTime: 30.0, endTime: 31.0, reviewStateRawValue: nil)
            ]
        )

        let a2 = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        let b2 = UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
        let c2 = UUID(uuidString: "60000000-0000-0000-0000-000000000003")!
        let current = [
            FeedbackReviewReplaySegment(id: c2, startTime: 30.12, endTime: 31.10, reviewStateRawValue: nil),
            FeedbackReviewReplaySegment(id: a2, startTime: 10.05, endTime: 12.04, reviewStateRawValue: nil),
            FeedbackReviewReplaySegment(id: b2, startTime: 19.92, endTime: 20.95, reviewStateRawValue: nil)
        ]

        switch FeedbackReviewReplayMatcher.match(
            template: template,
            currentVideoAssetIdentifier: "video-1",
            currentSegments: current
        ) {
        case .success(let match):
            expect(match.reviewedCount == 2, "only reviewed entries should be assigned")
            expect(match.assignments[a2] == "正解", "confirmed state must replay to matched segment")
            expect(match.assignments[b2] == "誤検出", "rejected state must replay to matched segment")
            expect(match.assignments[c2] == nil, "unreviewed entry must remain unreviewed")
        case .failure(let error):
            failures.append("valid replay unexpectedly failed: \(error.rawValue)")
        }

        let log = FeedbackReviewReplayMatcher.reviewLogString(template.segments)
        expect(log == "10.000-12.000=正解;20.000-21.000=誤検出", "review log must be deterministic and omit unreviewed entries")

        let wrongVideo = FeedbackReviewReplayMatcher.match(
            template: template,
            currentVideoAssetIdentifier: "video-2",
            currentSegments: current
        )
        if case .failure(.videoMismatch) = wrongVideo {} else {
            failures.append("video mismatch must fail before replay")
        }

        let missingSegment = FeedbackReviewReplayMatcher.match(
            template: template,
            currentVideoAssetIdentifier: "video-1",
            currentSegments: Array(current.prefix(2))
        )
        if case .failure(.segmentCountMismatch) = missingSegment {} else {
            failures.append("segment-count mismatch must fail atomically")
        }

        var shifted = current
        shifted[0] = FeedbackReviewReplaySegment(
            id: shifted[0].id,
            startTime: shifted[0].startTime + 0.5,
            endTime: shifted[0].endTime + 0.5,
            reviewStateRawValue: nil
        )
        let geometryMismatch = FeedbackReviewReplayMatcher.match(
            template: template,
            currentVideoAssetIdentifier: "video-1",
            currentSegments: shifted
        )
        if case .failure(.segmentGeometryMismatch) = geometryMismatch {} else {
            failures.append("geometry mismatch must fail without partial assignments")
        }

        if failures.isEmpty {
            print("Feedback rescan A/B diagnostics tests: PASS")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
