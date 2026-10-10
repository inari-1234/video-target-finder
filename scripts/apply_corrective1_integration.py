#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    if text.count(start) != 1:
        raise RuntimeError(f"{label}: start marker count={text.count(start)}")
    i = text.index(start)
    j = text.index(end, i)
    return text[:i] + replacement + text[j:]


vm_path = Path("VideoTargetFinder/VideoAnalysisViewModel.swift")
vm = vm_path.read_text(encoding="utf-8")

vm = replace_once(
    vm,
    "    @Published private(set) var lastFeedbackRescanAddedCount = 0\n",
    "    @Published private(set) var lastFeedbackRescanAddedCount = 0\n"
    "    @Published private(set) var lastFeedbackRescanMergedGapCount = 0\n"
    "    @Published private(set) var mergeCorrectiveEnabled = ContinuityCorrectiveFeatureFlags.defaultFeedbackRescanGapMerge\n"
    "    @Published private(set) var feedbackReviewReplayTemplateCount = 0\n",
    "published corrective state",
)
vm = replace_once(
    vm,
    "    private var feedbackRescanRuns: [FeedbackRescanRuntimeRun] = []\n",
    "    private var feedbackRescanRuns: [FeedbackRescanRuntimeRun] = []\n"
    "    private var segmentIDRemap = SegmentIDRemapTable()\n"
    "    private var retainedMergedLearnedReferences: [LearnedReference] = []\n"
    "    private var feedbackReviewReplayTemplate: FeedbackReviewReplayTemplate?\n",
    "private corrective state",
)

# A new video or changed reference set invalidates the recorded A/B review template.
vm = replace_once(
    vm,
    "                videoAssetIdentifier = identifier\n                resetResults()\n",
    "                videoAssetIdentifier = identifier\n                clearFeedbackReviewReplayTemplate()\n                resetResults()\n",
    "video change clears review replay",
)
vm = replace_once(
    vm,
    "        referenceImages = Array(images.prefix(5))\n        resetResults()\n",
    "        referenceImages = Array(images.prefix(5))\n        clearFeedbackReviewReplayTemplate()\n        resetResults()\n",
    "reference set clears review replay",
)
vm = replace_once(
    vm,
    "        referenceImages.remove(at: index)\n        resetResults()\n",
    "        referenceImages.remove(at: index)\n        clearFeedbackReviewReplayTemplate()\n        resetResults()\n",
    "reference removal clears review replay",
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

ab_runtime = r'''    func setMergeCorrectiveEnabled(_ enabled: Bool) {
        guard !isExclusiveWorkInProgress else { return }
        guard mergeCorrectiveEnabled != enabled else { return }
        mergeCorrectiveEnabled = enabled
        let hadAnalysisState = !segments.isEmpty || !candidates.isEmpty
        if hadAnalysisState {
            resetResults()
            statusMessage = "比較条件を変更しました。A/Bを混在させないため、初回探索からやり直してください。"
        } else {
            statusMessage = "学習再探索のmerge correctiveを\(enabled ? "ON" : "OFF")にしました。次の再探索開始時に固定されます。"
        }
        DiagnosticLogger.log(
            "merge-corrective-toggle value=\(enabled ? "ON" : "OFF") analysisReset=\(hadAnalysisState)"
        )
    }

    func recordFeedbackReviewSet() {
        guard !isExclusiveWorkInProgress else { return }
        guard let videoAssetIdentifier, !segments.isEmpty else {
            statusMessage = "判定セットを記録するには、初回探索と○/×判定が必要です。"
            return
        }
        guard segments.allSatisfy({ $0.discoverySource == .initial }) else {
            statusMessage = "判定セットは初回探索結果から記録してください。再探索後は初回探索をやり直してください。"
            return
        }
        let descriptors = feedbackReviewReplaySegments()
        let template = FeedbackReviewReplayMatcher.makeTemplate(
            videoAssetIdentifier: videoAssetIdentifier,
            segments: descriptors
        )
        feedbackReviewReplayTemplate = template
        feedbackReviewReplayTemplateCount = template.segments.filter { $0.reviewStateRawValue != nil }.count
        let reviewText = FeedbackReviewReplayMatcher.reviewLogString(template.segments)
        DiagnosticLogger.log("feedback-review-set-recorded count=\(feedbackReviewReplayTemplateCount) reviews=\(reviewText)")
        statusMessage = "現在の○/×判定を \(feedbackReviewReplayTemplateCount)件記録しました。A/Bの次条件で再適用できます。"
    }

    func applyRecordedFeedbackReviewSet() {
        guard !isExclusiveWorkInProgress else { return }
        guard let template = feedbackReviewReplayTemplate,
              let videoAssetIdentifier,
              !segments.isEmpty else {
            statusMessage = "再適用できる判定セットがありません。"
            return
        }
        guard segments.allSatisfy({ $0.discoverySource == .initial }) else {
            statusMessage = "判定セットは再探索前の初回探索結果にだけ再適用できます。"
            return
        }

        switch FeedbackReviewReplayMatcher.match(
            template: template,
            currentVideoAssetIdentifier: videoAssetIdentifier,
            currentSegments: feedbackReviewReplaySegments()
        ) {
        case .failure(let error):
            DiagnosticLogger.log("feedback-review-set-replay-failed reason=\(error.rawValue)")
            statusMessage = "判定セットを再適用できませんでした（\(error.rawValue)）。部分適用はしていません。"
        case .success(let match):
            for index in segments.indices {
                segments[index].reviewState = .unreviewed
                segments[index].isSelectedForExport = false
                segments[index].requiresReviewAfterMerge = false
            }
            for index in segments.indices {
                guard let rawValue = match.assignments[segments[index].id],
                      let state = SegmentReviewState(rawValue: rawValue) else { continue }
                segments[index].reviewState = state
                segments[index].isSelectedForExport = state == .confirmed
            }
            retainedMergedLearnedReferences = []
            segmentIDRemap.reset()
            refreshLearnedReferencesFromConfirmedSegments()
            feedbackThreshold = calculateSuggestedFeedbackThreshold()
            let reviewText = FeedbackReviewReplayMatcher.reviewLogString(feedbackReviewReplaySegments())
            DiagnosticLogger.log("feedback-review-set-replayed count=\(match.reviewedCount) reviews=\(reviewText)")
            statusMessage = "記録した○/×判定を \(match.reviewedCount)件再適用しました。"
        }
    }

    private func feedbackReviewReplaySegments() -> [FeedbackReviewReplaySegment] {
        segments.map { segment in
            FeedbackReviewReplaySegment(
                id: segment.id,
                startTime: segment.startTime,
                endTime: segment.endTime,
                reviewStateRawValue: segment.reviewState == .unreviewed ? nil : segment.reviewState.rawValue
            )
        }
    }

    private func clearFeedbackReviewReplayTemplate() {
        feedbackReviewReplayTemplate = nil
        feedbackReviewReplayTemplateCount = 0
    }

'''
vm = replace_once(
    vm,
    "    var canRunFeedbackRescan: Bool {\n",
    ab_runtime + "    var canRunFeedbackRescan: Bool {\n",
    "A/B runtime controls",
)

vm = replace_once(
    vm,
    "        let preservedSegments = segments\n"
    "        let rescanRunNumber = feedbackRescanRuns.count + 1\n",
    "        let preservedSegments = segments\n"
    "        let preservedLearnedReferences = learnedReferences\n"
    "        let preservedSegmentIDRemap = segmentIDRemap\n"
    "        let preservedRetainedMergedLearnedReferences = retainedMergedLearnedReferences\n"
    "        let mergeCorrectiveEnabledForRun = mergeCorrectiveEnabled\n"
    "        let rescanRunNumber = feedbackRescanRuns.count + 1\n"
    "        let reviewInputText = FeedbackReviewReplayMatcher.reviewLogString(feedbackReviewReplaySegments())\n"
    "        DiagnosticLogger.log(\"feedback-rescan-input run=\\(rescanRunNumber) mergeCorrective=\\(mergeCorrectiveEnabledForRun ? \\\"ON\\\" : \\\"OFF\\\") reviews=\\(reviewInputText)\")\n",
    "feedback run snapshot",
)
vm = replace_once(
    vm,
    "        lastFeedbackRescanAddedCount = 0\n        scanProgress = 0\n",
    "        lastFeedbackRescanAddedCount = 0\n        lastFeedbackRescanMergedGapCount = 0\n        scanProgress = 0\n",
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
new_merge_call = r'''                let mergeOutcome: (
                    segments: [DetectedSegment],
                    mergedGapCount: Int,
                    affectedCanonicalIDs: Set<UUID>
                )
                if mergeCorrectiveEnabledForRun {
                    mergeOutcome = self.mergeFeedbackRescanSegmentsCorrective(
                        existing: preservedSegments,
                        newSegments: rescannedSegments,
                        acceptedHitTimes: detail.hits.map(\.time),
                        observations: detail.observations,
                        flagEnabled: mergeCorrectiveEnabledForRun
                    )
                } else {
                    DiagnosticLogger.log("feedback-rescan-merge-mode run=\(rescanRunNumber) flag=OFF path=legacy")
                    mergeOutcome = (
                        self.mergeFeedbackRescanSegmentsLegacy(
                            existing: preservedSegments,
                            newSegments: rescannedSegments
                        ),
                        0,
                        []
                    )
                }
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
    "                self.segments = merged\n                self.refreshLearnedReferencesFromConfirmedSegments()\n",
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
vm = replace_once(
    vm,
    "            } catch is CancellationError {\n"
    "                self.segments = preservedSegments\n"
    "                self.scanPhase = \"キャンセル\"\n",
    "            } catch is CancellationError {\n"
    "                self.segments = preservedSegments\n"
    "                self.segmentIDRemap = preservedSegmentIDRemap\n"
    "                self.retainedMergedLearnedReferences = preservedRetainedMergedLearnedReferences\n"
    "                self.scanPhase = \"キャンセル\"\n",
    "feedback cancellation rollback",
)
vm = replace_once(
    vm,
    "            } catch {\n"
    "                self.segments = preservedSegments\n"
    "                self.errorMessage = error.localizedDescription\n"
    "                self.scanPhase = \"エラー\"\n"
    "                self.statusMessage = \"学習再探索に失敗しました。既存の判定は保持しています。\"\n",
    "            } catch {\n"
    "                self.segments = preservedSegments\n"
    "                self.segmentIDRemap = preservedSegmentIDRemap\n"
    "                self.retainedMergedLearnedReferences = preservedRetainedMergedLearnedReferences\n"
    "                self.errorMessage = error.localizedDescription\n"
    "                self.scanPhase = \"エラー\"\n"
    "                self.statusMessage = \"学習再探索に失敗しました。既存の判定は保持しています。\"\n",
    "feedback error rollback",
)

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

    // Build 35 compatibility path. When Corrective 1 is OFF this exact path is used and the
    // gap planner/remap/merged fields are not touched.
    private func mergeFeedbackRescanSegmentsLegacy(
        existing: [DetectedSegment],
        newSegments: [DetectedSegment]
    ) -> [DetectedSegment] {
        var result = existing
        let overlapTolerance: TimeInterval = 0.45

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

            if overlapsExisting {
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
            }

            if !overlapsExisting {
                var taggedCandidate = candidate
                taggedCandidate.discoverySource = .feedbackRescan
                result.append(taggedCandidate)
            }
        }

        return result.sorted { $0.startTime < $1.startTime }
    }

    private func mergeFeedbackRescanSegmentsCorrective(
        existing: [DetectedSegment],
        newSegments: [DetectedSegment],
        acceptedHitTimes: [TimeInterval],
        observations: [ScanPipelineObservation],
        flagEnabled: Bool
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

            var appliedForCandidate = 0
            if overlapsExisting {
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
                    enabled: flagEnabled
                )

                for decision in plan.decisions {
                    let hardNegativeText = decision.hardNegativeTimes.isEmpty
                        ? "none"
                        : decision.hardNegativeTimes.map { String(format: "%.3f", $0) }.joined(separator: ",")
                    DiagnosticLogger.log(
                        String(
                            format: "feedback-gap-decision flag=%@ candidate=%.3f-%.3f gap=%.3f-%.3f span=%.3fs hits=%d maxHitless=%.3fs hardNegative=%@ decision=%@ reason=%@",
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
                            decision.reason.rawValue
                        )
                    )
                }

                for group in plan.groups {
                    let memberIDSet = Set(group.memberIDs)
                    let members = result.filter { memberIDSet.contains($0.id) }
                    guard members.count == group.memberIDs.count,
                          let mergedSegment = materializeMergedSegment(group: group, members: members) else {
                        continue
                    }
                    var appliedRemap: [UUID: UUID] = [:]
                    for id in group.memberIDs where id != group.canonicalID {
                        appliedRemap[id] = group.canonicalID
                    }
                    segmentIDRemap.register(appliedRemap)
                    result.removeAll { memberIDSet.contains($0.id) }
                    result.append(mergedSegment)
                    affectedCanonicalIDs.insert(segmentIDRemap.resolve(group.canonicalID))
                    let appliedGapCount = max(0, group.memberIDs.count - 1)
                    appliedForCandidate += appliedGapCount
                    mergedGapCount += appliedGapCount
                    DiagnosticLogger.log(
                        String(
                            format: "feedback-rescan-gap-merged flag=ON canonical=%@ members=%@ range=%.3f-%.3f review=unreviewed export=false",
                            group.canonicalID.uuidString,
                            group.memberIDs.map(\.uuidString).joined(separator: ","),
                            group.startTime,
                            group.endTime
                        )
                    )
                }
            }

            if overlapsExisting && appliedForCandidate == 0 {
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
            } else if appliedForCandidate > 0 {
                DiagnosticLogger.log(
                    String(
                        format: "feedback-rescan-merge-consumed-as-evidence flag=ON candidate=%.3f-%.3f mergedGaps=%d",
                        candidate.startTime,
                        candidate.endTime,
                        appliedForCandidate
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
        let weightedDenominator = members.reduce(0) { $0 + max(1, $1.hitCount) }
        let weightedTracking = members.reduce(0.0) {
            $0 + $1.trackingScore * Double(max(1, $1.hitCount))
        } / Double(max(1, weightedDenominator))

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
content = replace_once(
    content,
    '                            Text("通常は1秒のままで構いません。")\n'
    '                                .font(.caption)\n'
    '                                .foregroundStyle(.secondary)\n',
    '                            Text("通常は1秒のままで構いません。")\n'
    '                                .font(.caption)\n'
    '                                .foregroundStyle(.secondary)\n'
    '\n'
    '                            Divider()\n'
    '                            Toggle(\n'
    '                                "診断: rescan gap merge corrective",\n'
    '                                isOn: Binding(\n'
    '                                    get: { viewModel.mergeCorrectiveEnabled },\n'
    '                                    set: { viewModel.setMergeCorrectiveEnabled($0) }\n'
    '                                )\n'
    '                            )\n'
    '                            .disabled(viewModel.isExclusiveWorkInProgress)\n'
    '                            Text("切替時はA/B混在防止のため解析結果をリセットし、初回探索からやり直します。再探索中は開始時の値で固定されます。")\n'
    '                                .font(.caption2)\n'
    '                                .foregroundStyle(.secondary)\n'
    '                            HStack {\n'
    '                                Button("現在の○/×を記録") {\n'
    '                                    viewModel.recordFeedbackReviewSet()\n'
    '                                }\n'
    '                                .buttonStyle(.bordered)\n'
    '                                Button("記録した○/×を再適用") {\n'
    '                                    viewModel.applyRecordedFeedbackReviewSet()\n'
    '                                }\n'
    '                                .buttonStyle(.bordered)\n'
    '                                .disabled(viewModel.feedbackReviewReplayTemplateCount == 0 || viewModel.isExclusiveWorkInProgress)\n'
    '                            }\n'
    '                            Text("A/B判定セット: \\(viewModel.feedbackReviewReplayTemplateCount)件")\n'
    '                                .font(.caption2.monospacedDigit())\n'
    '                                .foregroundStyle(.secondary)\n',
    "A/B corrective controls",
)
content = replace_once(
    content,
    '                    if viewModel.lastFeedbackRescanAddedCount > 0 {\n'
    '                        Label("前回の再探索で \\(viewModel.lastFeedbackRescanAddedCount)区間を追加", systemImage: "plus.circle.fill")\n'
    '                            .font(.subheadline)\n'
    '                    }\n',
    '                    if viewModel.lastFeedbackRescanAddedCount > 0 {\n'
    '                        Label("前回の再探索で \\(viewModel.lastFeedbackRescanAddedCount)区間を追加", systemImage: "plus.circle.fill")\n'
    '                            .font(.subheadline)\n'
    '                    }\n'
    '                    if viewModel.lastFeedbackRescanMergedGapCount > 0 {\n'
    '                        Label("前回の再探索で \\(viewModel.lastFeedbackRescanMergedGapCount)か所を統合・要再確認", systemImage: "link.circle.fill")\n'
    '                            .font(.subheadline)\n'
    '                    }\n',
    "merged count UI",
)
content_path.write_text(content, encoding="utf-8")

verify_path = Path("scripts/verify_source.py")
verify = verify_path.read_text(encoding="utf-8")
if '"fixtures"' not in verify.splitlines()[4]:
    verify = replace_once(
        verify,
        'ROOT_ALLOWED = {".github", ".gitignore", "README.md", "VideoTargetFinder", "docs", "project.yml", "scripts"}',
        'ROOT_ALLOWED = {".github", ".gitignore", "README.md", "VideoTargetFinder", "docs", "fixtures", "project.yml", "scripts"}',
        "fixtures root allow",
    )
verify = verify.replace('CURRENT_PROJECT_VERSION:\\s*35', 'CURRENT_PROJECT_VERSION:\\s*36')
verify = verify.replace('"Build 35 missing"', '"Build 36 missing"')
verify += r'''

# v0.32 Build 36 Corrective 1 runtime qualification guards.
corrective = Path("VideoTargetFinder/FeedbackRescanGapMergeCorrective.swift").read_text(encoding="utf-8")
ab_diag = Path("VideoTargetFinder/FeedbackRescanABDiagnostics.swift").read_text(encoding="utf-8")
quality_gate = Path("VideoTargetFinder/ContinuityQualityGate.swift").read_text(encoding="utf-8")
ground_truth = Path("fixtures/continuity_ground_truth_authority_v1.json").read_text(encoding="utf-8")
assert Path("scripts/test_feedback_rescan_gap_merge_corrective.swift").exists(), "Corrective 1 merge regression missing"
assert Path("scripts/test_feedback_rescan_ab_diagnostics.swift").exists(), "Feedback A/B replay regression missing"
assert Path("scripts/test_continuity_quality_gate.swift").exists(), "Continuity quality gate regression missing"
assert "maximumGapSpan: 4.0" in corrective, "Corrective 1 maximum gap must stay at 4.0s"
assert "maximumInteriorHitlessSpan: 1.25" in corrective, "Longest hitless span guard missing"
assert "defaultFeedbackRescanGapMerge = false" in corrective, "Corrective 1 must default OFF for A/B"
assert "static let initialTierCBridge = false" in corrective, "Tier-C must remain disabled during Corrective 1"
assert "mergeCorrectiveEnabledForRun = mergeCorrectiveEnabled" in view_model, "Rescan flag must be snapshotted at run start"
assert "mergeFeedbackRescanSegmentsLegacy" in view_model, "OFF path must retain legacy merge implementation"
assert "feedback-rescan-merge-mode run=" in view_model and "flag=OFF path=legacy" in view_model, "OFF legacy provenance log missing"
assert "feedback-gap-decision flag=%@" in view_model, "Per-gap flag/reason diagnostic missing"
assert "segmentIDRemap.register" in view_model and "segmentIDRemap.resolve" in view_model, "Segment ID remap integration missing"
assert "segmentIDRemap.reset()" in view_model, "Segment ID remap reset missing"
assert "requiresReviewAfterMerge: true" in view_model, "Merged segment must require user re-review"
assert "reviewState: .unreviewed" in view_model and "isSelectedForExport: false" in view_model, "Merged review/export reset missing"
assert "preserveMergedLearnedReferences" in view_model, "Merged positive learned references must be retained"
assert "retainedMergedLearnedReferences.removeAll" in view_model, "Rejecting merged canonical must remove retained positives"
assert "feedback-review-set-recorded" in view_model and "feedback-review-set-replayed" in view_model, "A/B review capture/replay runtime missing"
assert "FeedbackReviewReplayMatcher.match" in view_model, "A/B review replay must be geometry-validated"
assert "feedback-rescan-input run=" in view_model and "reviews=" in view_model, "Per-run A/B input log missing"
assert 'Text("統合済み・要確認")' in content, "Merged segment re-review marker missing"
assert '"診断: rescan gap merge corrective"' in content, "Corrective 1 runtime toggle missing"
assert '"現在の○/×を記録"' in content and '"記録した○/×を再適用"' in content, "A/B review replay controls missing"
assert 'case mergedFeedback = "初回＋学習再探索"' in detected_segment, "Merged discovery provenance missing"
assert '"label": "same_appearance"' in ground_truth and '"label": "unknown"' in ground_truth, "Ground-truth partial Authority labels missing"
assert "ContinuityQualityGateAnalyzer" in quality_gate, "Appearance-based quality gate missing"
assert "FeedbackReviewReplayMatcher" in ab_diag, "A/B review replay core missing"
'''
verify_path.write_text(verify, encoding="utf-8")

# One-shot integration helper must not survive the source commit.
Path("scripts/apply_corrective1_integration.py").unlink()
print("Corrective 1 runtime integration patch: APPLIED")
