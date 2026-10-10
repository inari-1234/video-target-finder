import Foundation

@main
struct FeedbackRescanGapMergeCorrectiveTests {
    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func near(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 0.001) -> Bool {
            abs(lhs - rhs) <= tolerance
        }

        let s1 = FeedbackMergeExistingSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startTime: 597.338,
            endTime: 612.133,
            isRejected: false
        )
        let s2 = FeedbackMergeExistingSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            startTime: 619.550,
            endTime: 620.350,
            isRejected: false
        )
        let s3 = FeedbackMergeExistingSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            startTime: 622.838,
            endTime: 625.377,
            isRejected: false
        )

        // DIAG-2 real geometry. The first 7.417s gap remains split; the verified 2.488s gap is eligible.
        let denseHits = stride(from: 612.35, through: 624.75, by: 0.25).map { $0 }
        let realEvidence = FeedbackRescanGapEvidence(
            candidateStartTime: 595.585,
            candidateEndTime: 624.892,
            acceptedHitTimes: denseHits,
            hardNegativeTimes: []
        )
        let realPlan = FeedbackRescanGapMergePlanner.plan(
            existing: [s1, s2, s3],
            evidence: realEvidence,
            enabled: true
        )
        expect(realPlan.decisions.count == 2, "real fixture should evaluate two absorbed gaps")
        expect(realPlan.decisions[0].reason == .gapTooLong, "7.417s gap must remain split")
        expect(realPlan.decisions[1].reason == .accepted, "2.488s central gap should pass evidence gate")
        expect(realPlan.groups.count == 1, "only the central pair should merge")
        if let group = realPlan.groups.first {
            expect(group.canonicalID == s2.id, "leftmost central segment must be canonical")
            expect(group.memberIDs == [s2.id, s3.id], "central group membership mismatch")
            expect(near(group.startTime, 619.550), "merged start must come from existing segment union")
            expect(near(group.endTime, 625.377), "merged end must come from existing segment union")
        }
        expect(realPlan.remap[s3.id] == s2.id, "right segment must remap to canonical")
        expect(realPlan.remap[s1.id] == nil, "unsafe left segment must not be remapped")

        // OFF/OFF compatibility: no corrective merge is permitted.
        let offPlan = FeedbackRescanGapMergePlanner.plan(
            existing: [s1, s2, s3],
            evidence: realEvidence,
            enabled: false
        )
        expect(offPlan.groups.isEmpty, "feature OFF must not create groups")
        expect(offPlan.remap.isEmpty, "feature OFF must not create remaps")
        expect(offPlan.decisions.allSatisfy { $0.reason == .featureDisabled }, "feature OFF reason mismatch")

        // A rejected existing segment is a hard boundary.
        let rejectedS3 = FeedbackMergeExistingSegment(
            id: s3.id,
            startTime: s3.startTime,
            endTime: s3.endTime,
            isRejected: true
        )
        let rejectedPlan = FeedbackRescanGapMergePlanner.plan(
            existing: [s2, rejectedS3],
            evidence: realEvidence,
            enabled: true
        )
        expect(rejectedPlan.groups.isEmpty, "rejected boundary must block merge")
        expect(rejectedPlan.decisions.first?.reason == .rejectedSegmentBoundary, "rejected boundary reason mismatch")

        // A hard negative inside the gap vetoes the merge.
        let hardNegativePlan = FeedbackRescanGapMergePlanner.plan(
            existing: [s2, s3],
            evidence: FeedbackRescanGapEvidence(
                candidateStartTime: 619.0,
                candidateEndTime: 625.0,
                acceptedHitTimes: [620.7, 621.0, 621.3, 621.6, 621.9, 622.2, 622.5],
                hardNegativeTimes: [621.45]
            ),
            enabled: true
        )
        expect(hardNegativePlan.groups.isEmpty, "hard negative must veto merge")
        expect(hardNegativePlan.decisions.first?.reason == .hardNegativeVeto, "hard negative reason mismatch")

        // Hit count alone is insufficient when hits are clustered on one side.
        let clusteredPlan = FeedbackRescanGapMergePlanner.plan(
            existing: [s2, s3],
            evidence: FeedbackRescanGapEvidence(
                candidateStartTime: 619.0,
                candidateEndTime: 625.0,
                acceptedHitTimes: [620.45, 620.55, 620.65, 620.75, 620.85, 620.95],
                hardNegativeTimes: []
            ),
            enabled: true
        )
        expect(clusteredPlan.groups.isEmpty, "clustered hits must not satisfy coverage")
        expect(clusteredPlan.decisions.first?.reason == .excessiveHitlessSpan, "coverage must use longest hitless span")

        // Remap resolution is transitive and compressed.
        let a = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        var table = SegmentIDRemapTable()
        table.register([c: b])
        table.register([b: a])
        expect(table.resolve(c) == a, "remap chain C→B→A must resolve to A")
        expect(table.resolve(b) == a, "remap B→A mismatch")

        // Re-applying the same rescan after the central pair has already merged is idempotent.
        let mergedCentral = FeedbackMergeExistingSegment(
            id: s2.id,
            startTime: 619.550,
            endTime: 625.377,
            isRejected: false
        )
        let secondPlan = FeedbackRescanGapMergePlanner.plan(
            existing: [s1, mergedCentral],
            evidence: realEvidence,
            enabled: true
        )
        expect(secondPlan.groups.isEmpty, "second identical rescan must not merge again")
        expect(secondPlan.remap.isEmpty, "second identical rescan must not create duplicate remap")

        if failures.isEmpty {
            print("Feedback rescan gap merge corrective tests: PASS")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
