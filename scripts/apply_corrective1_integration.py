#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    start_count = text.count(start)
    end_count = text.count(end)
    if start_count != 1 or end_count != 1:
        raise RuntimeError(f"{label}: marker counts start={start_count}, end={end_count}")
    i = text.index(start)
    j = text.index(end, i)
    return text[:i] + replacement + text[j:]


vm_path = Path("VideoTargetFinder/VideoAnalysisViewModel.swift")
vm = vm_path.read_text(encoding="utf-8")

vm = replace_once(
    vm,
    "    @Published private(set) var lastFeedbackRescanAddedCount = 0\n",
    "    @Published private(set) var lastFeedbackRescanAddedCount = 0\n"
    "    @Published private(set) var lastFeedbackRescanMergedGapCount = 0\n",
    "published merged gap count",
)
vm = replace_once(
    vm,
    "    private var feedbackRescanRuns: [FeedbackRescanRuntimeRun] = []\n",
    "    private var feedbackRescanRuns: [FeedbackRescanRuntimeRun] = []\n"
    "    private var segmentIDRemap = SegmentIDRemapTable()\n"
    "    private var retainedMergedLearnedReferences: [LearnedReference] = []\n",
    "runtime remap state",
)

new_review = r'''    func reviewSegment(id: UUID, as state: SegmentReviewState) {
        guard !isExclusiveWorkInProgress else { return }
        let resolvedID = segmentIDRemap.resolve(id)
        guard let index = segments.firstIndex(where: { $0.id == resolvedID }) else { return }
        let changedDiscoverySource = segments[index].discoverySource
        segments[index].reviewState = state
        segments[index].requiresReviewAfterMerge = false
        if changedDiscoverySource == .feedbackRescan || changedDiscoverySource == .mergedFeedback {
            foregroundReserveRerankSummary = nil
        }
        if changedDiscoverySource == .initial || changedDiscoverySource == .mergedFeedback {
            trackingSeedQualitySummary = nil
            objectTrackingBenchmarkSummary = nil
        }

        switch state {
        case .confirmed:
            segments[index].isSelectedForExport = true
        case .rejected:
            segments[index].isSelectedForExport = false
            retainedMergedLearnedReferences.removeAll {
                segmentIDRemap.resolve($0.sourceSegmentID) == resolvedID
            }
        case .unreviewed:
            break
        }

        refreshLearnedReferencesFromConfirmedSegments()
        feedbackThreshold = calculateSuggestedFeedbackThreshold()
        statusMessage = "判定を更新しました。正解 \(confirmedCount) / 誤検出 \(rejectedCount) / 未判定 \(unreviewedCount) / 学習見本 \(learnedReferences.count)"
        persistRecognitionReportSnapshot(reason: "review-updated")
    }

'''
vm = replace_between(
    vm,
    "    func reviewSegment(id: UUID, as state: SegmentReviewState) {",
    "    func toggleSegmentSelection(id: UUID) {",
    new_review,
    "reviewSegment",
)
vm = replace_once(
    vm,
    "    func toggleSegmentSelection(id: UUID) {\n"
    "        guard !isExclusiveWorkInProgress else { return }\n"
    "        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }\n",
    "    func toggleSegmentSelection(id: UUID) {\n"
    "        guard !isExclusiveWorkInProgress else { return }\n"
    "        let resolvedID = segmentIDRemap.resolve(id)\n"
    "        guard let index = segments.firstIndex(where: { $0.id == resolvedID }) else { return }\n",
    "toggle remap",
)
vm = replace_once(
    vm,
    "        let preservedSegments = segments\n"
    "        let rescanRunNumber = feedbackRescanRuns.count + 1\n",
    "        let preservedSegments = segments\n"
    "        let preservedLearnedReferences = learnedReferences\n"
    "        let rescanRunNumber = feedbackRescanRuns.count + 1\n",
    "feedback snapshot",
)
vm = replace_once(
    vm,
    "        lastFeedbackRescanAddedCount = 0\n"
    "        scanProgress = 0\n",
    "        lastFeedbackRescanAddedCount = 0\n"
    "        lastFeedbackRescanMergedGapCount = 0\n"
    "        scanProgress = 0\n",
    "feedback merged count reset",
)

old_merge_call = r'''                let merged = self.mergeFeedbackRescanSegments(
                    existing: preservedSegments,
                    newSegments: rescannedSegments
                )
                let preservedIDs = Set(preservedSegments.map(\.id))
                let addedIDs = merged
                    .filter { !preservedIDs.contains($0.id) }
                    .map(\.id)
                self.lastFeedbackRescanAddedCount = addedIDs.count
'''
new_merge_call = r'''                let mergeOutcome = self.mergeFeedbackRescanSegments(
                    existing: preservedSegments,
                    newSegments: rescannedSegments,
                    acceptedHitTimes: detail.hits.map(\.time),
                    observations: detail.observations
                )
                let merged = mergeOutcome.segments
                let preservedIDs = Set(preservedSegments.map(\.id))
                let addedIDs = merged
                    .filter { !preservedIDs.contains($0.id) }
                    .map(\.id)
                self.lastFeedbackRescanAddedCount = addedIDs.count
                self.lastFeedbackRescanMergedGapCount = mergeOutcome.mergedGapCount
'''
vm = replace_once(vm, old_merge_call, new_merge_call, "merge call")
vm = replace_once(
    vm,
    "                self.segments = merged\n"
    "                self.refreshLearnedReferencesFromConfirmedSegments()\n",
    "                self.segments = merged\n"
    "                self.preserveMergedLearnedReferences(\n"
    "                    preservedLearnedReferences,\n"
    "                    affectedCanonicalIDs: mergeOutcome.affectedCanonicalIDs\n"
    "                )\n"
    "                self.refreshLearnedReferencesFromConfirmedSegments()\n",
    "preserve merged learned refs",
)
old_status = r'''                self.statusMessage = self.lastFeedbackRescanAddedCount == 0
                    ? "学習再探索が完了しました。新しい非重複候補はありませんでした。"
                    : "学習再探索で新しい候補を \(self.lastFeedbackRescanAddedCount)区間追加しました。"
'''
new_status = r'''                if self.lastFeedbackRescanMergedGapCount > 0 {
                    let addedText = self.lastFeedbackRescanAddedCount > 0
                        ? " 新しい非重複候補も \(self.lastFeedbackRescanAddedCount)区間追加しました。"
                        : ""
                    self.statusMessage = "\(self.lastFeedbackRescanMergedGapCount)か所の分断を統合しました。統合済み区間を再確認してください。" + addedText
                } else {
                    self.statusMessage = self.lastFeedbackRescanAddedCount == 0
                        ? "学習再探索が完了しました。新しい非重複候補はありませんでした。"
                        : "学習再探索で新しい候補を \(self.lastFeedbackRescanAddedCount)区間追加しました。"
                }
'''
vm = replace_once(vm, old_status, new_status, "feedback completion status")

new_merge_helpers = r'''    private func refreshLearnedReferencesFromConfirmedSegments() {
        let rejectedIDs = Set(segments.filter { $0.reviewState == .rejected }.map(\.id))
        retainedMergedLearnedReferences = retainedMergedLearnedReferences.compactMap { reference in
            let resolvedID = segmentIDRemap.resolve(reference.sourceSegmentID)
            guard !rejectedIDs.contains(resolvedID) else { return nil }
            return LearnedReference(
                id: reference.id,
                sourceSegmentID: resolvedID,
                image: reference.image,
                sourceTime: reference.sourceTime
            )
        }

        var combined: [LearnedReference] = []
        for reference in retainedMergedLearnedReferences {
            appendLearnedReferenceIfDistinct(reference, to: &combined)
        }

        let confirmed = segments
            .filter { $0.reviewState == .confirmed }
            .sorted { $0.bestDistance < $1.bestDistance }
        for segment in confirmed {
            appendLearnedReferenceIfDistinct(
                LearnedReference(
                    sourceSegmentID: segmentIDRemap.resolve(segment.id),
                    image: segment.matchThumbnail,
                    sourceTime: segment.bestTime
                ),
                to: &combined
            )
        }

        learnedReferences = Array(combined.prefix(8))
    }

    private func appendLearnedReferenceIfDistinct(
        _ reference: LearnedReference,
        to list: inout [LearnedReference]
    ) {
        let canonicalID = segmentIDRemap.resolve(reference.sourceSegmentID)
        let duplicate = list.contains {
            segmentIDRemap.resolve($0.sourceSegmentID) == canonicalID &&
            abs($0.sourceTime - reference.sourceTime) <= 0.001
        }
        guard !duplicate else { return }
        list.append(
            LearnedReference(
                id: reference.id,
                sourceSegmentID: canonicalID,
                image: reference.image,
                sourceTime: reference.sourceTime
            )
        )
    }

    private func preserveMergedLearnedReferences(
        _ previous: [LearnedReference],
        affectedCanonicalIDs: Set<UUID>
    ) {
        guard !affectedCanonicalIDs.isEmpty else { return }
        for reference in previous {
            let canonicalID = segmentIDRemap.resolve(reference.sourceSegmentID)
            guard affectedCanonicalIDs.contains(canonicalID) else { continue }
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
    }

    private func mergeFeedbackRescanSegments(
        existing: [DetectedSegment],
        newSegments: [DetectedSegment],
        acceptedHitTimes: [TimeInterval],
        observations: [ScanPipelineObservation]
    ) -> (
        segments: [DetectedSegment],
        mergedGapCount: Int,
        affectedCanonicalIDs: Set<UUID>
    ) {
        var result = existing
        let overlapTolerance: TimeInterval = 0.45
        var mergedGapCount = 0
        var affectedCanonicalIDs = Set<UUID>()

        for candidate in newSegments.sorted(by: { $0.startTime < $1.startTime }) {
            let overlapsExisting = result.contains { current in
                candidate.startTime <= current.endTime + overlapTolerance &&
                candidate.endTime >= current.startTime - overlapTolerance
            }

            let diagnostic = SegmentFeedbackMergeDiagnosticAnalyzer.evaluate(
                candidate: SegmentFeedbackMergeDescriptor(
                    startTime: candidate.startTime,
                    endTime: candidate.endTime,
                    discoverySource: bridgeDiagnosticSourceLabel(candidate.discoverySource),
                    hitCount: candidate.hitCount,
                    trackingScore: candidate.trackingScore
                ),
                existing: result.map {
                    SegmentFeedbackMergeDescriptor(
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        discoverySource: bridgeDiagnosticSourceLabel($0.discoverySource),
                        hitCount: $0.hitCount,
                        trackingScore: $0.trackingScore
                    )
                },
                overlapTolerance: overlapTolerance
            )

            var correctiveApplied = false
            if overlapsExisting && ContinuityCorrectiveFeatureFlags.feedbackRescanGapMerge {
                let candidateHits = acceptedHitTimes.filter {
                    $0 >= candidate.startTime - overlapTolerance &&
                    $0 <= candidate.endTime + overlapTolerance
                }
                let hardNegatives = observations.filter {
                    $0.rejectedByNegative &&
                    $0.time >= candidate.startTime - overlapTolerance &&
                    $0.time <= candidate.endTime + overlapTolerance
                }.map(\.time)
                let plan = FeedbackRescanGapMergePlanner.plan(
                    existing: result.map {
                        FeedbackMergeExistingSegment(
                            id: $0.id,
                            startTime: $0.startTime,
                            endTime: $0.endTime,
                            isRejected: $0.reviewState == .rejected
                        )
                    },
                    evidence: FeedbackRescanGapEvidence(
                        candidateStartTime: candidate.startTime,
                        candidateEndTime: candidate.endTime,
                        acceptedHitTimes: candidateHits,
                        hardNegativeTimes: hardNegatives
                    ),
                    enabled: true
                )

                for decision in plan.decisions {
                    let hardNegativeText = decision.hardNegativeTimes.isEmpty
                        ? "none"
                        : decision.hardNegativeTimes.map { String(format: "%.3f", $0) }.joined(separator: ",")
                    DiagnosticLogger.log(
                        String(
                            format: "feedback-rescan-gap-decision candidate=%.3f-%.3f gap=%.3f-%.3f span=%.3fs hits=%d maxHitless=%.3fs hardNegative=%@ decision=%@ reason=%@",
                            candidate.startTime,
                            candidate.endTime,
                            decision.gapStartTime,
                            decision.gapEndTime,
                            decision.gapSpan,
                            decision.interiorHitCount,
                            decision.maximumHitlessSpan,
                            hardNegativeText,
                            decision.shouldMerge ? "merge" : "split",
                            decision.reason.rawValue
                        )
                    )
                }

                if !plan.groups.isEmpty {
                    segmentIDRemap.register(plan.remap)
                    for group in plan.groups {
                        let memberIDSet = Set(group.memberIDs)
                        let members = result.filter { memberIDSet.contains($0.id) }
                        guard members.count == group.memberIDs.count,
                              let mergedSegment = materializeMergedSegment(group: group, members: members) else {
                            continue
                        }
                        result.removeAll { memberIDSet.contains($0.id) }
                        result.append(mergedSegment)
                        affectedCanonicalIDs.insert(segmentIDRemap.resolve(group.canonicalID))
                        DiagnosticLogger.log(
                            String(
                                format: "feedback-rescan-gap-merged canonical=%@ members=%@ range=%.3f-%.3f review=unreviewed export=false",
                                group.canonicalID.uuidString,
                                group.memberIDs.map(\.uuidString).joined(separator: ","),
                                group.startTime,
                                group.endTime
                            )
                        )
                    }
                    mergedGapCount += plan.decisions.filter(\.shouldMerge).count
                    correctiveApplied = true
                }
            }

            if overlapsExisting && !correctiveApplied {
                let overlapText = diagnostic.overlaps.map {
                    String(
                        format: "%.3f-%.3f(source=%@,overlap=%.3fs,toleranceAdjusted=%.3fs)",
                        $0.existingStartTime,
                        $0.existingEndTime,
                        $0.existingDiscoverySource,
                        $0.overlapAmount,
                        $0.toleranceAdjustedOverlapAmount
                    )
                }.joined(separator: ";")
                DiagnosticLogger.log(
                    String(
                        format: "feedback-rescan-merge-discarded stage=final/merge candidate=%.3f-%.3f source=%@ hitCount=%d trackingScore=%.3f overlapCount=%d spansMultipleExisting=%@ overlaps=%@",
                        candidate.startTime,
                        candidate.endTime,
                        bridgeDiagnosticSourceLabel(candidate.discoverySource),
                        candidate.hitCount,
                        candidate.trackingScore,
                        diagnostic.overlaps.count,
                        diagnostic.spansMultipleExistingSegments ? "true" : "false",
                        overlapText
                    )
                )
            } else if correctiveApplied {
                DiagnosticLogger.log(
                    String(
                        format: "feedback-rescan-merge-consumed-as-evidence candidate=%.3f-%.3f mergedGaps=%d",
                        candidate.startTime,
                        candidate.endTime,
                        mergedGapCount
                    )
                )
            }

            if !overlapsExisting {
                var taggedCandidate = candidate
                taggedCandidate.discoverySource = .feedbackRescan
                result.append(taggedCandidate)
            }
        }

        return (
            result.sorted { $0.startTime < $1.startTime },
            mergedGapCount,
            affectedCanonicalIDs
        )
    }

    private func materializeMergedSegment(
        group: FeedbackRescanMergeGroup,
        members: [DetectedSegment]
    ) -> DetectedSegment? {
        guard !members.isEmpty else { return nil }
        let sorted = members.sorted {
            if abs($0.startTime - $1.startTime) > 0.000_001 {
                return $0.startTime < $1.startTime
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard sorted.first?.id == group.canonicalID else { return nil }
        let best = members.min {
            if abs($0.bestDistance - $1.bestDistance) > 0.000_001 {
                return $0.bestDistance < $1.bestDistance
            }
            return $0.bestTime < $1.bestTime
        } ?? sorted[0]
        let totalHits = members.reduce(0) { $0 + max(0, $1.hitCount) }
        let weightedTracking = members.reduce(0.0) {
            $0 + $1.trackingScore * Double(max(1, $1.hitCount))
        } / Double(max(1, members.reduce(0) { $0 + max(1, $1.hitCount) }))

        return DetectedSegment(
            id: group.canonicalID,
            startTime: group.startTime,
            endTime: group.endTime,
            bestTime: best.bestTime,
            bestDistance: best.bestDistance,
            thumbnail: best.thumbnail,
            matchThumbnail: best.matchThumbnail,
            referenceIndex: best.referenceIndex,
            regionLabel: best.regionLabel,
            hitCount: totalHits,
            trackingScore: weightedTracking,
            aggregationScores: best.aggregationScores,
            discoverySource: .mergedFeedback,
            reviewState: .unreviewed,
            isSelectedForExport: false,
            requiresReviewAfterMerge: true
        )
    }

'''
vm = replace_between(
    vm,
    "    private func refreshLearnedReferencesFromConfirmedSegments() {",
    "    private func makeDetailWindows(",
    new_merge_helpers,
    "learned refs and merge corrective",
)

new_source_label = r'''    private func bridgeDiagnosticSourceLabel(_ source: SegmentDiscoverySource) -> String {
        switch source {
        case .initial:
            return "initial"
        case .feedbackRescan:
            return "feedback-rescan"
        case .mergedFeedback:
            return "initial+feedback-rescan"
        }
    }

'''
vm = replace_between(
    vm,
    "    private func bridgeDiagnosticSourceLabel(_ source: SegmentDiscoverySource) -> String {",
    "    private func continuityTrackingSeed(",
    new_source_label,
    "bridge source label",
)

vm = replace_once(
    vm,
    "        learnedReferences = []\n"
    "        lastFeedbackRescanAddedCount = 0\n"
    "        feedbackRescanRuns = []\n",
    "        learnedReferences = []\n"
    "        retainedMergedLearnedReferences = []\n"
    "        segmentIDRemap.reset()\n"
    "        lastFeedbackRescanAddedCount = 0\n"
    "        lastFeedbackRescanMergedGapCount = 0\n"
    "        feedbackRescanRuns = []\n",
    "reset corrective state",
)
vm_path.write_text(vm, encoding="utf-8")

content_path = Path("VideoTargetFinder/ContentView.swift")
content = content_path.read_text(encoding="utf-8")
content = replace_once(
    content,
    '                                    Text("発見元: \\(segment.discoverySource.rawValue)")\n'
    '                                    Text("Feature distance: \\(segment.distanceText)").monospacedDigit()\n',
    '                                    Text("発見元: \\(segment.discoverySource.rawValue)")\n'
    '                                    if segment.requiresReviewAfterMerge {\n'
    '                                        Text("統合済み・要確認")\n'
    '                                            .fontWeight(.semibold)\n'
    '                                    }\n'
    '                                    Text("Feature distance: \\(segment.distanceText)").monospacedDigit()\n',
    "merged review UI marker",
)
content_path.write_text(content, encoding="utf-8")

project_path = Path("project.yml")
project = project_path.read_text(encoding="utf-8")
project = replace_once(project, "CURRENT_PROJECT_VERSION: 35", "CURRENT_PROJECT_VERSION: 36", "build number")
project_path.write_text(project, encoding="utf-8")

workflow_path = Path(".github/workflows/ios-build.yml")
workflow = workflow_path.read_text(encoding="utf-8")
workflow = workflow.replace("build35", "build36")
workflow = replace_once(workflow, 'test "$(/usr/libexec/PlistBuddy -c \'Print :CFBundleVersion\' "$APP/Info.plist")" = "35"', 'test "$(/usr/libexec/PlistBuddy -c \'Print :CFBundleVersion\' "$APP/Info.plist")" = "36"', "IPA build verify")
anchor = "          swiftc VideoTargetFinder/SegmentFeedbackMergeDiagnostics.swift scripts/test_diag2_rescan_merge.swift -o /tmp/diag2-rescan-merge-tests\n          /tmp/diag2-rescan-merge-tests\n"
addition = anchor + "\n          swiftc VideoTargetFinder/FeedbackRescanGapMergeCorrective.swift scripts/test_feedback_rescan_gap_merge_corrective.swift -o /tmp/corrective1-gap-merge-tests\n          /tmp/corrective1-gap-merge-tests\n\n          swiftc VideoTargetFinder/ContinuityQualityGate.swift scripts/test_continuity_quality_gate.swift -o /tmp/continuity-quality-gate-tests\n          /tmp/continuity-quality-gate-tests\n"
workflow = replace_once(workflow, anchor, addition, "workflow corrective tests")
workflow_path.write_text(workflow, encoding="utf-8")

verify_path = Path("scripts/verify_source.py")
verify = verify_path.read_text(encoding="utf-8")
verify = replace_once(
    verify,
    'ROOT_ALLOWED = {".github", ".gitignore", "README.md", "VideoTargetFinder", "docs", "project.yml", "scripts"}',
    'ROOT_ALLOWED = {".github", ".gitignore", "README.md", "VideoTargetFinder", "docs", "fixtures", "project.yml", "scripts"}',
    "fixtures root allow",
)
verify = replace_once(verify, 'CURRENT_PROJECT_VERSION:\\s*35', 'CURRENT_PROJECT_VERSION:\\s*36', "verify build regex")
verify = replace_once(verify, '"Build 35 missing"', '"Build 36 missing"', "verify build message")
verify += r'''

# v0.32 Build 36 Corrective 1: gap-evidence feedback merge is guarded, deterministic and review-safe.
corrective = Path("VideoTargetFinder/FeedbackRescanGapMergeCorrective.swift").read_text(encoding="utf-8")
quality_gate = Path("VideoTargetFinder/ContinuityQualityGate.swift").read_text(encoding="utf-8")
ground_truth = Path("fixtures/continuity_ground_truth_authority_v1.json").read_text(encoding="utf-8")
assert Path("scripts/test_feedback_rescan_gap_merge_corrective.swift").exists(), "Corrective 1 merge regression missing"
assert Path("scripts/test_continuity_quality_gate.swift").exists(), "Continuity quality gate regression missing"
assert "maximumGapSpan: 4.0" in corrective, "Corrective 1 maximum gap must start conservatively at 4.0s"
assert "maximumInteriorHitlessSpan: 1.25" in corrective, "Longest hitless span guard missing"
assert "maximumMergedSegmentCount: 3" in corrective, "Merged segment-count limit missing"
assert "maximumMergedDuration: 20.0" in corrective, "Merged duration limit missing"
assert "static let initialTierCBridge = false" in corrective, "Tier-C must remain disabled during Corrective 1"
assert "segmentIDRemap.register" in view_model, "Runtime segment ID remap integration missing"
assert "segmentIDRemap.resolve" in view_model, "Transitive segment ID resolution missing"
assert "requiresReviewAfterMerge: true" in view_model, "Merged segment must require user re-review"
assert "reviewState: .unreviewed" in view_model, "Merged segment review state must reset"
assert "isSelectedForExport: false" in view_model, "Merged segment export selection must reset"
assert "preserveMergedLearnedReferences" in view_model, "Merged positive learned references must be retained"
assert "retainedMergedLearnedReferences.removeAll" in view_model, "Rejecting merged segment must remove retained positives"
assert "feedback-rescan-gap-decision" in view_model, "Per-gap corrective decision logging missing"
assert "feedback-rescan-gap-merged" in view_model, "Applied corrective merge logging missing"
assert 'Text("統合済み・要確認")' in content, "Merged segment re-review marker missing"
assert 'case mergedFeedback = "初回＋学習再探索"' in detected_segment, "Merged discovery provenance missing"
assert '"label": "same_appearance"' in ground_truth and '"label": "unknown"' in ground_truth, "Ground-truth partial Authority labels missing"
assert "ContinuityQualityGateAnalyzer" in quality_gate, "Appearance-based quality gate missing"
'''
verify_path.write_text(verify, encoding="utf-8")

# The bootstrap mechanism must not survive the integration commit.
Path("scripts/apply_corrective1_integration.py").unlink()
Path(".github/workflows/corrective1-bootstrap.yml").unlink()

print("Corrective 1 integration patch: APPLIED")
