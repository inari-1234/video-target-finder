#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, got {count}")
    return text.replace(old, new, 1)

# 1) Carry exact merge-limit context out of the pure planner without changing policy thresholds.
core_path = Path("VideoTargetFinder/FeedbackRescanGapMergeCorrective.swift")
core = core_path.read_text(encoding="utf-8")
old_decision = '''struct FeedbackRescanGapDecision: Sendable, Equatable {
    let leftSegmentID: UUID
    let rightSegmentID: UUID
    let gapStartTime: TimeInterval
    let gapEndTime: TimeInterval
    let gapSpan: TimeInterval
    let interiorHitCount: Int
    let maximumHitlessSpan: TimeInterval
    let hardNegativeTimes: [TimeInterval]
    let shouldMerge: Bool
    let reason: FeedbackRescanGapMergeReason
}
'''
new_decision = '''struct FeedbackRescanMergeLimitContext: Sendable, Equatable {
    let proposedSegmentCount: Int
    let maximumSegmentCount: Int
    let proposedDuration: TimeInterval
    let maximumDuration: TimeInterval
    let segmentCountExceeded: Bool
    let durationExceeded: Bool
}

struct FeedbackRescanGapDecision: Sendable, Equatable {
    let leftSegmentID: UUID
    let rightSegmentID: UUID
    let gapStartTime: TimeInterval
    let gapEndTime: TimeInterval
    let gapSpan: TimeInterval
    let interiorHitCount: Int
    let maximumHitlessSpan: TimeInterval
    let hardNegativeTimes: [TimeInterval]
    let shouldMerge: Bool
    let reason: FeedbackRescanGapMergeReason
    let mergeLimitContext: FeedbackRescanMergeLimitContext?
}
'''
core = replace_once(core, old_decision, new_decision, "decision model")

old_limit = '''                let proposedStart = proposedMembers.map(\\.startTime).min() ?? left.startTime
                let proposedEnd = proposedMembers.map(\\.endTime).max() ?? right.endTime
                if proposedMembers.count > policy.maximumMergedSegmentCount ||
                    proposedEnd - proposedStart > policy.maximumMergedDuration {
                    decision = FeedbackRescanGapDecision(
                        leftSegmentID: decision.leftSegmentID,
                        rightSegmentID: decision.rightSegmentID,
                        gapStartTime: decision.gapStartTime,
                        gapEndTime: decision.gapEndTime,
                        gapSpan: decision.gapSpan,
                        interiorHitCount: decision.interiorHitCount,
                        maximumHitlessSpan: decision.maximumHitlessSpan,
                        hardNegativeTimes: decision.hardNegativeTimes,
                        shouldMerge: false,
                        reason: .mergeLimitExceeded
                    )
                    finalizeCurrentGroup()
                    currentGroup = [right]
                } else {
                    currentGroup = proposedMembers
                }
'''
new_limit = '''                let proposedStart = proposedMembers.map(\\.startTime).min() ?? left.startTime
                let proposedEnd = proposedMembers.map(\\.endTime).max() ?? right.endTime
                let proposedDuration = proposedEnd - proposedStart
                let segmentCountExceeded = proposedMembers.count > policy.maximumMergedSegmentCount
                let durationExceeded = proposedDuration > policy.maximumMergedDuration
                let limitContext = FeedbackRescanMergeLimitContext(
                    proposedSegmentCount: proposedMembers.count,
                    maximumSegmentCount: policy.maximumMergedSegmentCount,
                    proposedDuration: proposedDuration,
                    maximumDuration: policy.maximumMergedDuration,
                    segmentCountExceeded: segmentCountExceeded,
                    durationExceeded: durationExceeded
                )
                if segmentCountExceeded || durationExceeded {
                    decision = FeedbackRescanGapDecision(
                        leftSegmentID: decision.leftSegmentID,
                        rightSegmentID: decision.rightSegmentID,
                        gapStartTime: decision.gapStartTime,
                        gapEndTime: decision.gapEndTime,
                        gapSpan: decision.gapSpan,
                        interiorHitCount: decision.interiorHitCount,
                        maximumHitlessSpan: decision.maximumHitlessSpan,
                        hardNegativeTimes: decision.hardNegativeTimes,
                        shouldMerge: false,
                        reason: .mergeLimitExceeded,
                        mergeLimitContext: limitContext
                    )
                    finalizeCurrentGroup()
                    currentGroup = [right]
                } else {
                    decision = FeedbackRescanGapDecision(
                        leftSegmentID: decision.leftSegmentID,
                        rightSegmentID: decision.rightSegmentID,
                        gapStartTime: decision.gapStartTime,
                        gapEndTime: decision.gapEndTime,
                        gapSpan: decision.gapSpan,
                        interiorHitCount: decision.interiorHitCount,
                        maximumHitlessSpan: decision.maximumHitlessSpan,
                        hardNegativeTimes: decision.hardNegativeTimes,
                        shouldMerge: decision.shouldMerge,
                        reason: decision.reason,
                        mergeLimitContext: limitContext
                    )
                    currentGroup = proposedMembers
                }
'''
core = replace_once(core, old_limit, new_limit, "merge limit context")

old_result = '''                hardNegativeTimes: hardNegatives,
                shouldMerge: shouldMerge,
                reason: reason
            )
'''
new_result = '''                hardNegativeTimes: hardNegatives,
                shouldMerge: shouldMerge,
                reason: reason,
                mergeLimitContext: nil
            )
'''
core = replace_once(core, old_result, new_result, "gap result initializer")
core_path.write_text(core, encoding="utf-8")

# 2) Strengthen the pure regression with exact limit attribution.
test_path = Path("scripts/test_feedback_rescan_gap_merge_corrective.swift")
test = test_path.read_text(encoding="utf-8")
old_real = '''        expect(realPlan.decisions[1].reason == .accepted, "2.488s central gap should pass evidence gate")
        expect(realPlan.groups.count == 1, "only the central pair should merge")
'''
new_real = '''        expect(realPlan.decisions[1].reason == .accepted, "2.488s central gap should pass evidence gate")
        expect(realPlan.decisions[1].mergeLimitContext?.proposedSegmentCount == 2, "central merge should evaluate two members")
        expect(near(realPlan.decisions[1].mergeLimitContext?.proposedDuration ?? -1, 5.827), "central merged duration context mismatch")
        expect(realPlan.groups.count == 1, "only the central pair should merge")
'''
test = replace_once(test, old_real, new_real, "real fixture limit context")
old_member = '''        expect(limitPlan.decisions.last?.reason == .mergeLimitExceeded, "fourth member must be blocked by merge limit")
'''
new_member = '''        expect(limitPlan.decisions.last?.reason == .mergeLimitExceeded, "fourth member must be blocked by merge limit")
        expect(limitPlan.decisions.last?.mergeLimitContext?.segmentCountExceeded == true, "member-cap failure must identify segment-count limit")
        expect(limitPlan.decisions.last?.mergeLimitContext?.maximumSegmentCount == 3, "member-cap limit value mismatch")
        expect(limitPlan.decisions.last?.mergeLimitContext?.durationExceeded == false, "member-cap fixture must not falsely report duration limit")
'''
test = replace_once(test, old_member, new_member, "member limit assertions")
old_duration = '''        expect(durationPlan.decisions.last?.reason == .mergeLimitExceeded, "duration cap must report merge-limit-exceeded")
'''
new_duration = '''        expect(durationPlan.decisions.last?.reason == .mergeLimitExceeded, "duration cap must report merge-limit-exceeded")
        expect(durationPlan.decisions.last?.mergeLimitContext?.durationExceeded == true, "duration-cap failure must identify duration limit")
        expect(near(durationPlan.decisions.last?.mergeLimitContext?.maximumDuration ?? -1, 20.0), "duration-cap limit value mismatch")
        expect(durationPlan.decisions.last?.mergeLimitContext?.segmentCountExceeded == false, "duration-cap fixture must not falsely report member limit")
'''
test = replace_once(test, old_duration, new_duration, "duration limit assertions")
test_path.write_text(test, encoding="utf-8")

# 3) Runtime evidence: limit values, final segment snapshot, learned-reference remap/delete counts.
vm_path = Path("VideoTargetFinder/VideoAnalysisViewModel.swift")
vm = vm_path.read_text(encoding="utf-8")

old_review_head = '''        let changedDiscoverySource = segments[index].discoverySource
        segments[index].reviewState = state
'''
new_review_head = '''        let changedDiscoverySource = segments[index].discoverySource
        let learnedReferenceCountBeforeReview = learnedReferences.filter {
            segmentIDRemap.resolve($0.sourceSegmentID) == resolvedID
        }.count
        let retainedReferenceCountBeforeReview = retainedMergedLearnedReferences.filter {
            segmentIDRemap.resolve($0.sourceSegmentID) == resolvedID
        }.count
        segments[index].reviewState = state
'''
vm = replace_once(vm, old_review_head, new_review_head, "review pre-counts")

old_review_refresh = '''        refreshLearnedReferencesFromConfirmedSegments()
        feedbackThreshold = calculateSuggestedFeedbackThreshold()
        statusMessage = "判定を更新しました。正解 \\(confirmedCount) / 誤検出 \\(rejectedCount) / 未判定 \\(unreviewedCount) / 学習見本 \\(learnedReferences.count)"
'''
new_review_refresh = '''        refreshLearnedReferencesFromConfirmedSegments()
        if case .rejected = state, changedDiscoverySource == .mergedFeedback {
            let learnedReferenceCountAfterReview = learnedReferences.filter {
                segmentIDRemap.resolve($0.sourceSegmentID) == resolvedID
            }.count
            let retainedReferenceCountAfterReview = retainedMergedLearnedReferences.filter {
                segmentIDRemap.resolve($0.sourceSegmentID) == resolvedID
            }.count
            DiagnosticLogger.log(
                "feedback-learned-reference-reject canonical=\\(resolvedID.uuidString) learnedRemoved=\\(max(0, learnedReferenceCountBeforeReview - learnedReferenceCountAfterReview)) retainedRemoved=\\(max(0, retainedReferenceCountBeforeReview - retainedReferenceCountAfterReview)) learnedRemaining=\\(learnedReferences.count) retainedRemaining=\\(retainedMergedLearnedReferences.count)"
            )
        }
        feedbackThreshold = calculateSuggestedFeedbackThreshold()
        statusMessage = "判定を更新しました。正解 \\(confirmedCount) / 誤検出 \\(rejectedCount) / 未判定 \\(unreviewedCount) / 学習見本 \\(learnedReferences.count)"
'''
vm = replace_once(vm, old_review_refresh, new_review_refresh, "review deletion evidence")

loop_start = vm.index("                for decision in plan.decisions {")
loop_end = vm.index("                for group in plan.groups {", loop_start)
old_loop = vm[loop_start:loop_end]
new_loop = '''                for decision in plan.decisions {
                    let hardNegativeText = decision.hardNegativeTimes.isEmpty
                        ? "none"
                        : decision.hardNegativeTimes.map { String(format: "%.3f", $0) }.joined(separator: ",")
                    let mergeLimitText: String
                    if let context = decision.mergeLimitContext {
                        var exceeded: [String] = []
                        if context.segmentCountExceeded { exceeded.append("segment-count") }
                        if context.durationExceeded { exceeded.append("merged-duration") }
                        let exceededText = exceeded.isEmpty ? "none" : exceeded.joined(separator: ",")
                        mergeLimitText = String(
                            format: " mergeMembers=%d/%d mergedDuration=%.3fs/%.3fs exceeded=%@",
                            context.proposedSegmentCount,
                            context.maximumSegmentCount,
                            context.proposedDuration,
                            context.maximumDuration,
                            exceededText
                        )
                    } else {
                        mergeLimitText = ""
                    }
                    DiagnosticLogger.log(
                        String(
                            format: "feedback-gap-decision flag=%@ candidate=%.3f-%.3f gap=%.3f-%.3f span=%.3fs hits=%d maxHitless=%.3fs hardNegative=%@ decision=%@ reason=%@%@",
                            flagEnabled ? "ON" : "OFF",
                            candidate.startTime,
                            candidate.endTime,
                            decision.gapStartTime,
                            decision.gapEndTime,
                            decision.gapSpan,
                            decision.interiorHitCount,
                            decision.maximumHitlessSpan,
                            hardNegativeText,
                            decision.shouldMerge ? "merge" : "split",
                            decision.reason.rawValue,
                            mergeLimitText
                        )
                    )
                }

'''
vm = vm[:loop_start] + new_loop + vm[loop_end:]

# Replace the preservation function wholesale using stable surrounding anchors.
preserve_start = vm.index("    private func preserveMergedLearnedReferences(")
preserve_end = vm.index("    // Build 35 compatibility path.", preserve_start)
new_preserve = '''    private func preserveMergedLearnedReferences(
        _ previous: [LearnedReference],
        affectedCanonicalIDs: Set<UUID>
    ) {
        guard !affectedCanonicalIDs.isEmpty else { return }
        let retainedBefore = retainedMergedLearnedReferences.count
        var matched = 0
        for reference in previous {
            let canonicalID = segmentIDRemap.resolve(reference.sourceSegmentID)
            guard affectedCanonicalIDs.contains(canonicalID) else { continue }
            matched += 1
            appendLearnedReferenceIfDistinct(
                LearnedReference(
                    id: reference.id,
                    sourceSegmentID: canonicalID,
                    image: reference.image,
                    sourceTime: reference.sourceTime
                ),
                to: &retainedMergedLearnedReferences
            )
        }
        DiagnosticLogger.log(
            "feedback-learned-reference-remap affectedCanonicals=\\(affectedCanonicalIDs.count) matched=\\(matched) retainedAdded=\\(max(0, retainedMergedLearnedReferences.count - retainedBefore)) retainedTotal=\\(retainedMergedLearnedReferences.count)"
        )
    }

'''
vm = vm[:preserve_start] + new_preserve + vm[preserve_end:]

# Add a compact, grep-friendly final segment snapshot helper before learned-reference refresh.
refresh_anchor = "    private func refreshLearnedReferencesFromConfirmedSegments() {"
helper = '''    private func logFeedbackFinalSegmentSnapshot(runNumber: Int, flagText: String) {
        let ordered = segments.sorted {
            if abs($0.startTime - $1.startTime) > 0.000_001 { return $0.startTime < $1.startTime }
            return $0.id.uuidString < $1.id.uuidString
        }
        DiagnosticLogger.log("feedback-final-segment-snapshot run=\\(runNumber) flag=\\(flagText) count=\\(ordered.count)")
        for (offset, segment) in ordered.enumerated() {
            DiagnosticLogger.log(
                String(
                    format: "feedback-final-segment run=%d flag=%@ index=%d range=%.3f-%.3f source=%@ review=%@ export=%@ needsReview=%@",
                    runNumber,
                    flagText,
                    offset + 1,
                    segment.startTime,
                    segment.endTime,
                    segment.discoverySource.rawValue,
                    segment.reviewState.rawValue,
                    segment.isSelectedForExport ? "true" : "false",
                    segment.requiresReviewAfterMerge ? "true" : "false"
                )
            )
        }
    }

'''
if refresh_anchor not in vm:
    raise SystemExit("final segment helper anchor missing")
vm = vm.replace(refresh_anchor, helper + refresh_anchor, 1)

old_completion = '''                self.refreshLearnedReferencesFromConfirmedSegments()
                self.feedbackThreshold = self.calculateSuggestedFeedbackThreshold()
                self.scanProgress = 1
'''
new_completion = '''                self.refreshLearnedReferencesFromConfirmedSegments()
                self.logFeedbackFinalSegmentSnapshot(
                    runNumber: rescanRunNumber,
                    flagText: mergeCorrectiveFlagText
                )
                self.feedbackThreshold = self.calculateSuggestedFeedbackThreshold()
                self.scanProgress = 1
'''
vm = replace_once(vm, old_completion, new_completion, "final segment snapshot call")
vm_path.write_text(vm, encoding="utf-8")

# 4) Build 37 identifies the logging-only diagnostic candidate unambiguously.
project_path = Path("project.yml")
project = project_path.read_text(encoding="utf-8")
project = replace_once(project, "CURRENT_PROJECT_VERSION: 36", "CURRENT_PROJECT_VERSION: 37", "project build")
project_path.write_text(project, encoding="utf-8")

workflow_path = Path(".github/workflows/ios-build.yml")
workflow = workflow_path.read_text(encoding="utf-8")
workflow = workflow.replace("build36", "build37").replace('= "36"', '= "37"')
workflow_path.write_text(workflow, encoding="utf-8")

verify_path = Path("scripts/verify_source.py")
verify = verify_path.read_text(encoding="utf-8")
verify = replace_once(verify, 'CURRENT_PROJECT_VERSION:\\s*36", project), "Build 36 missing"', 'CURRENT_PROJECT_VERSION:\\s*37", project), "Build 37 missing"', "verify build")
# Add runtime-evidence guards next to the existing Build 36/Corrective 1 source guards without altering production logic.
guard_anchor = 'assert "feedbackRescanRuns" in view_model, "Runtime rescan history missing"\n'
extra_guards = '''assert "feedback-gap-decision flag=%@" in view_model and "mergeMembers=%d/%d" in view_model, "Corrective 1 merge-limit evidence logging missing"\nassert "feedback-final-segment-snapshot" in view_model, "Corrective 1 final segment snapshot logging missing"\nassert "feedback-learned-reference-remap" in view_model, "Merged learned-reference remap evidence missing"\nassert "feedback-learned-reference-reject" in view_model, "Merged learned-reference rejection evidence missing"\n'''
if guard_anchor not in verify:
    raise SystemExit("verify guard anchor missing")
verify = verify.replace(guard_anchor, guard_anchor + extra_guards, 1)
verify_path.write_text(verify, encoding="utf-8")

print("Corrective 1 runtime evidence patch applied")
