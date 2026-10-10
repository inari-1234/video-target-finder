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
        expect(rejectedPlan.decisions.first?.reason == .rejectedSegmentVeto, "rejected candidate veto reason mismatch")

        // A rejected segment anywhere inside one spanning rescan candidate vetoes all partial merges.
        // This prevents the planner from merging s2+s3 merely because the unsafe s1+s2 gap also split.
        let rejectedS1 = FeedbackMergeExistingSegment(
            id: s1.id,
            startTime: s1.startTime,
            endTime: s1.endTime,
            isRejected: true
        )
        let spanningRejectedPlan = FeedbackRescanGapMergePlanner.plan(
            existing: [rejectedS1, s2, s3],
            evidence: realEvidence,
            enabled: true
        )
        expect(spanningRejectedPlan.groups.isEmpty, "any rejected segment spanned by a candidate must veto every merge")
        expect(
            spanningRejectedPlan.decisions.allSatisfy { $0.reason == .rejectedSegmentVeto },
            "spanning rejected candidate must report global veto for every evaluated gap"
        )

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

        // Deterministic ordering: equal starts are ordered by UUID string.
        let tieA = FeedbackMergeExistingSegment(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            startTime: 100.0,
            endTime: 100.5,
            isRejected: false
        )
        let tieB = FeedbackMergeExistingSegment(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            startTime: 100.0,
            endTime: 100.4,
            isRejected: false
        )
        let tieC = FeedbackMergeExistingSegment(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            startTime: 101.5,
            endTime: 102.0,
            isRejected: false
        )
        let tiePlan = FeedbackRescanGapMergePlanner.plan(
            existing: [tieB, tieC, tieA],
            evidence: FeedbackRescanGapEvidence(
                candidateStartTime: 99.8,
                candidateEndTime: 102.1,
                acceptedHitTimes: [100.7, 100.9, 101.1, 101.3],
                hardNegativeTimes: []
            ),
            enabled: true
        )
        expect(tiePlan.decisions.first?.leftSegmentID == tieA.id, "equal-start ordering must use deterministic UUID tie-break")
        expect(tiePlan.decisions.first?.reason == .nonPositiveGap, "overlapping equal-start segments must remain split")

        // Maximum merged member count remains an independent safety cap.
        let limitSegments = (0..<4).map { index in
            FeedbackMergeExistingSegment(
                id: UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", index + 1))!,
                startTime: Double(index) * 1.5,
                endTime: Double(index) * 1.5 + 0.5,
                isRejected: false
            )
        }
        let limitEvidence = FeedbackRescanGapEvidence(
            candidateStartTime: -0.1,
            candidateEndTime: 5.1,
            acceptedHitTimes: stride(from: 0.65, through: 4.45, by: 0.25).map { $0 },
            hardNegativeTimes: []
        )
        let limitPlan = FeedbackRescanGapMergePlanner.plan(
            existing: limitSegments,
            evidence: limitEvidence,
            enabled: true
        )
        expect(limitPlan.groups.count == 1, "member cap should preserve the first safe subgroup")
        expect(limitPlan.groups.first?.memberIDs.count == 3, "member cap must stop at three existing segments")
        expect(limitPlan.decisions.last?.reason == .mergeLimitExceeded, "fourth member must be blocked by merge limit")

        // Maximum merged duration is also enforced even when every individual gap is short and dense.
        let longA = FeedbackMergeExistingSegment(id: UUID(), startTime: 0, endTime: 9.5, isRejected: false)
        let longB = FeedbackMergeExistingSegment(id: UUID(), startTime: 10.0, endTime: 19.5, isRejected: false)
        let longC = FeedbackMergeExistingSegment(id: UUID(), startTime: 20.0, endTime: 29.5, isRejected: false)
        let durationPlan = FeedbackRescanGapMergePlanner.plan(
            existing: [longA, longB, longC],
            evidence: FeedbackRescanGapEvidence(
                candidateStartTime: 0,
                candidateEndTime: 29.5,
                acceptedHitTimes: [9.7, 9.9, 19.7, 19.9],
                hardNegativeTimes: []
            ),
            enabled: true
        )
        expect(durationPlan.groups.count == 1, "duration cap should still permit first safe pair")
        expect(durationPlan.groups.first?.memberIDs.count == 2, "duration cap must prevent adding third long member")
        expect(durationPlan.decisions.last?.reason == .mergeLimitExceeded, "duration cap must report merge-limit-exceeded")

        // Remap resolution is transitive and compressed.
        let a = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        var table = SegmentIDRemapTable()
        table.register([c: b])
        table.register([b: a])
        expect(table.resolve(c) == a, "remap chain C→B→A must resolve to A")
        expect(table.resolve(b) == a, "remap B→A mismatch")

        // Learned positives survive a merge with source IDs remapped, but rejecting the merged
        // canonical removes only that canonical's retained positives.
        let otherCanonical = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
        var learnedRemap = SegmentIDRemapTable()
        learnedRemap.register([s3.id: s2.id])
        let learnedBefore = [
            LearnedReferenceIdentity(id: UUID(), sourceSegmentID: s2.id, sourceTime: 619.95),
            LearnedReferenceIdentity(id: UUID(), sourceSegmentID: s3.id, sourceTime: 623.238),
            LearnedReferenceIdentity(id: UUID(), sourceSegmentID: otherCanonical, sourceTime: 700.0)
        ]
        let retainedForMerge = MergedLearnedReferenceIdentityPolicy.retainedForMergedCanonicals(
            learnedBefore,
            affectedCanonicalIDs: [s2.id],
            remap: learnedRemap
        )
        expect(retainedForMerge.count == 2, "both old positives from the merged pair must be retained")
        expect(retainedForMerge.allSatisfy { $0.sourceSegmentID == s2.id }, "retained positive source IDs must remap to canonical")
        let allRetained = retainedForMerge + [learnedBefore[2]]
        let afterReject = MergedLearnedReferenceIdentityPolicy.removingRejectedCanonical(
            s2.id,
            from: allRetained,
            remap: learnedRemap
        )
        expect(afterReject.count == 1, "rejecting merged canonical must remove its retained positives")
        expect(afterReject.first?.sourceSegmentID == otherCanonical, "rejecting merged canonical must preserve unrelated positive")

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
