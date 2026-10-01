import Foundation

struct DistanceStatistics: Sendable, Codable {
    let count: Int
    let minimum: Float?
    let mean: Float?
    let maximum: Float?

    static func make(_ values: [Float]) -> DistanceStatistics {
        guard !values.isEmpty else {
            return DistanceStatistics(count: 0, minimum: nil, mean: nil, maximum: nil)
        }
        let total = values.reduce(Float(0), +)
        return DistanceStatistics(
            count: values.count,
            minimum: values.min(),
            mean: total / Float(values.count),
            maximum: values.max()
        )
    }

    var compactText: String {
        guard let minimum, let mean, let maximum else { return "データなし" }
        return String(format: "min %.4f / mean %.4f / max %.4f", minimum, mean, maximum)
    }
}

struct ReferenceQualityEvaluation: Identifiable, Sendable, Codable {
    let id: Int
    let label: String
    let matchCount: Int
    let confirmedCount: Int
    let rejectedCount: Int
    let unreviewedCount: Int
    let contributionPercent: Double
    let positiveMeanDistance: Float?
    let negativeMeanDistance: Float?
    let grade: String
    let comment: String
}

struct FeedbackRescanRunSummary: Identifiable, Sendable, Codable {
    let runNumber: Int
    let addedCount: Int
    let confirmedCount: Int
    /// v0.29以降。旧保存レポートではnil。
    let rejectedCount: Int?
    /// v0.20以降。旧保存レポートではnil。
    let coarseCandidateLimit: Int?
    let coarseCandidateCount: Int?
    let positiveReferenceCount: Int?
    let hardNegativeCount: Int?
    /// v0.30以降。旧保存レポートではnil（旧方式はnearest）。
    let positiveAggregationMode: String?
    /// v0.31以降。初回粗探索Feature Printを再利用したサンプル数。
    let coarseFeatureCacheHits: Int?
    /// v0.31以降。再探索時に新規Feature Print生成が必要だったサンプル数。
    let coarseFeatureFreshSamples: Int?
    /// v0.32以降。初回詳細探索Feature Printを再利用したサンプル数。
    let detailFeatureCacheHits: Int?
    /// v0.32以降。再探索詳細で新規Feature Print生成が必要だったサンプル数。
    let detailFeatureFreshSamples: Int?

    var id: Int { runNumber }

    var reviewedPrecision: Double? {
        guard let rejectedCount else { return nil }
        let reviewed = confirmedCount + rejectedCount
        guard reviewed > 0 else { return nil }
        return Double(confirmedCount) / Double(reviewed)
    }

    var reviewedPrecisionText: String {
        reviewedPrecision?.formatted(.percent.precision(.fractionLength(0))) ?? "判定不足"
    }
}

struct RecognitionQualityReport: Sendable, Codable {
    let generatedAt: Date
    /// v0.20以降。旧保存レポートではnil。
    let evaluationSchemaVersion: Int?
    let recognitionEngine: String?
    let targetLabel: String
    let videoDurationText: String
    let videoResolutionText: String
    let videoFrameRateText: String
    let videoComment: String

    let referenceCount: Int
    let learnedReferenceCount: Int
    let hardNegativeCount: Int
    let candidateCount: Int
    let segmentCount: Int
    let confirmedCount: Int
    let rejectedCount: Int
    let unreviewedCount: Int
    let reviewedPrecision: Double?
    let rescanAddedCount: Int
    let rescanConfirmedCount: Int
    /// v0.29以降。旧保存レポートではnil。
    let rescanRejectedCount: Int?
    let missedSuspicionCount: Int
    /// v0.19以降。nil は旧バージョンの保存レポートを復旧した場合。
    let rescanRuns: [FeedbackRescanRunSummary]?
    /// 初回粗探索で分析用に多めに候補を保持し、再探索正解がどの段階で落ちたかを推定する。
    /// v0.20以降。旧保存レポートではnil。
    let candidateBudgetAnalysis: CandidateBudgetAnalysisSummary?
    /// v0.21以降。現行nearestで候補化された判定済み区間だけを使う集約方式A/B診断。
    let referenceAggregationBenchmark: ReferenceAggregationBenchmarkSummary?
    /// v0.29以降。学習再探索で追加された判定済み区間だけを使う集約方式A/B診断。
    let feedbackRescanAggregationBenchmark: ReferenceAggregationBenchmarkSummary?
    /// v0.24以降。旧保存レポートではnil。
    let maskingBenchmark: MaskingBenchmarkSummary?
    /// v0.25以降。analysis reserve内の候補時刻を固定したforeground shadow再順位。
    let foregroundReserveRerank: ForegroundReserveRerankSummary?
    /// v0.26以降。foreground instanceから作るtracking seed boxの品質診断。
    let trackingSeedQuality: TrackingSeedQualitySummary?
    /// v0.27以降。VNTrackObjectRequestを使うtight/padded seed A/B診断。
    let objectTrackingBenchmark: ObjectTrackingBenchmarkSummary?
    /// v0.23以降。旧保存レポートではnil。
    let scanPerformanceRuns: [ScanPerformanceRunSummary]?
    let averageTrackingScore: Double?
    let positiveDistances: DistanceStatistics
    let negativeDistances: DistanceStatistics
    let threshold: Float?
    let thresholdOverlaps: Bool
    let reportConfidence: String

    let currentSensitivity: String
    let currentCoarseInterval: Double
    let currentDetailInterval: Double
    let recommendedSensitivity: String
    let recommendedCoarseInterval: Double
    let recommendedDetailInterval: Double

    let referenceEvaluations: [ReferenceQualityEvaluation]
    let falsePositiveComments: [String]
    let missedDetectionComments: [String]
    let guidance: [String]

    var reviewedPrecisionText: String {
        guard let reviewedPrecision else { return "判定不足" }
        return reviewedPrecision.formatted(.percent.precision(.fractionLength(0)))
    }

    var initialSegmentCount: Int {
        max(0, segmentCount - rescanAddedCount)
    }

    var rescanReviewedPrecision: Double? {
        guard let rescanRejectedCount else { return nil }
        let reviewed = rescanConfirmedCount + rescanRejectedCount
        guard reviewed > 0 else { return nil }
        return Double(rescanConfirmedCount) / Double(reviewed)
    }

    var rescanReviewedPrecisionText: String {
        rescanReviewedPrecision?.formatted(.percent.precision(.fractionLength(0))) ?? "判定不足"
    }

    var rescanHistoryText: String {
        guard let rescanRuns, !rescanRuns.isEmpty else { return "履歴なし" }
        return rescanRuns.map { run in
            var details = "Rescan #\(run.runNumber): added \(run.addedCount), confirmed \(run.confirmedCount)"
            if let rejected = run.rejectedCount {
                details += ", rejected \(rejected), precision \(run.reviewedPrecisionText)"
            }
            if let count = run.coarseCandidateCount, let limit = run.coarseCandidateLimit {
                details += ", coarse \(count)/\(limit)"
            }
            if let positives = run.positiveReferenceCount, let negatives = run.hardNegativeCount {
                details += ", refs +\(positives)/-\(negatives)"
            }
            if let mode = run.positiveAggregationMode {
                details += ", positive aggregation \(mode)"
            }
            if let hits = run.coarseFeatureCacheHits,
               let fresh = run.coarseFeatureFreshSamples {
                details += ", coarse Feature cache \(hits) reused / \(fresh) fresh"
            }
            if let hits = run.detailFeatureCacheHits,
               let fresh = run.detailFeatureFreshSamples {
                details += ", detail Feature cache \(hits) reused / \(fresh) fresh"
            }
            return details
        }.joined(separator: " / ")
    }

    var summaryText: String {
        var parts: [String] = []
        if let reviewedPrecision {
            parts.append("判定済み候補の正解率 約\(reviewedPrecision.formatted(.percent.precision(.fractionLength(0))))")
        } else {
            parts.append("正解率はまだ判定数不足")
        }
        if rescanConfirmedCount > 0 {
            parts.append("再探索で正解 \(rescanConfirmedCount)件を追加発見")
        }
        if thresholdOverlaps {
            parts.append("正解/誤検出の距離が重複")
        }
        if let budget = candidateBudgetAnalysis, budget.outsideInitialBudgetCount > 0 {
            parts.append("初回候補予算外 \(budget.outsideInitialBudgetCount)件")
        }
        return parts.joined(separator: "・")
    }

    var textReport: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = [
            "Video Target Finder - Recognition Quality Report",
            "Generated: \(formatter.string(from: generatedAt))",
            "Evaluation schema: \(evaluationSchemaVersion.map(String.init) ?? "legacy")",
            "Recognition engine: \(recognitionEngine ?? "legacy / unknown")",
            "Target: \(targetLabel.isEmpty ? "(未入力)" : targetLabel)",
            "Report confidence: \(reportConfidence)",
            "",
            "=== Video ===",
            "Duration: \(videoDurationText)",
            "Resolution: \(videoResolutionText)",
            "Frame rate: \(videoFrameRateText)",
            "Short comment: \(videoComment)",
            "",
            "=== Recognition Summary ===",
            "Reference Images: \(referenceCount)",
            "Learned Positive References: \(learnedReferenceCount)",
            "Hard Negatives: \(hardNegativeCount)",
            "Coarse Candidates (current): \(candidateCount)",
            "Detected Segments: \(segmentCount)",
            "Initial detected segments: \(initialSegmentCount)",
            "Confirmed: \(confirmedCount)",
            "Rejected: \(rejectedCount)",
            "Undecided: \(unreviewedCount)",
            "Reviewed-candidate precision: \(reviewedPrecisionText)",
            "Feedback-rescan total added: \(rescanAddedCount)",
            "Feedback-rescan total confirmed: \(rescanConfirmedCount)",
            "Feedback-rescan total rejected: \(rescanRejectedCount.map(String.init) ?? "legacy / unknown")",
            "Feedback-rescan reviewed precision: \(rescanReviewedPrecisionText)",
            "Feedback-rescan history: \(rescanHistoryText)",
            "Missed-detection suspicions: \(missedSuspicionCount)",
            "Positive distance: \(positiveDistances.compactText)",
            "Negative distance: \(negativeDistances.compactText)",
            "Suggested threshold: \(threshold.map { String(format: "%.4f", $0) } ?? "not available")",
            "Threshold overlap: \(thresholdOverlaps ? "YES" : "NO")",
            "Average temporal hit coverage: \(averageTrackingScore.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "n/a")",
            "",
            "=== Initial Candidate Budget Analysis ==="
        ]

        if let budget = candidateBudgetAnalysis {
            lines.append("Initial detail budget: \(budget.initialDetailBudget)")
            lines.append("Initial analysis reserve: \(budget.initialReserveCount)/\(budget.initialReserveLimit)")
            lines.append("Rescan confirmed analyzed: \(budget.rescanConfirmedCount)")
            lines.append("Within initial detail budget: \(budget.withinInitialBudgetCount)")
            lines.append("Outside initial detail budget but in reserve: \(budget.outsideInitialBudgetCount)")
            lines.append("Not found in initial reserve: \(budget.notInInitialReserveCount)")
            if let curve = budget.coverageCurve, !curve.isEmpty {
                let curveText = curve.map { point in
                    let ratio = point.coverageRatio?.formatted(.percent.precision(.fractionLength(0))) ?? "n/a"
                    return "K=\(point.budget): \(point.coveredCount)/\(point.totalConfirmedCount) (\(ratio))"
                }.joined(separator: " / ")
                lines.append("Known-positive rank coverage: \(curveText)")
            }
            if let diversity = budget.temporalDiversity {
                lines.append("Temporal diversity bins: \(diversity.binCount), budget: \(diversity.budget) (analysis reserve only)")
                lines.append("Global top-K occupied bins: \(diversity.globalOccupiedBinCount)/\(diversity.binCount)")
                lines.append("Time-diverse occupied bins: \(diversity.timeDiverseOccupiedBinCount)/\(diversity.binCount)")
                lines.append("Known-positive coverage global/time-diverse: \(diversity.globalCoveredCount)/\(diversity.timeDiverseCoveredCount) of \(diversity.knownPositiveCount)")
            }
        } else {
            lines.append("(not available; legacy/incomplete recovery data or reserve-prefix consistency check failed)")
        }

        lines.append("")
        lines.append("=== Vision Object Tracking A/B Diagnostic ===")
        if let tracking = objectTrackingBenchmark {
            lines.append("Candidates: \(tracking.candidateCount), seeded: \(tracking.seededCandidateCount), seed failures: \(tracking.seedFailureCount)")
            for variant in [tracking.tight, tracking.padded] {
                lines.append("\(variant.variant.displayName): attempted \(variant.attemptedFrameCount), tracked \(variant.trackedFrameCount), comparable \(variant.comparableFrameCount)")
                lines.append("  continuation rate: \(variant.continuationRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "n/a")")
                lines.append("  reference agreement: \(variant.referenceAgreementRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "n/a")")
                lines.append("  mean confidence: \(variant.meanConfidence.map { String(format: "%.3f", $0) } ?? "n/a")")
                lines.append("  mean reference IoU: \(variant.meanReferenceIoU.map { String(format: "%.3f", $0) } ?? "n/a")")
                lines.append("  mean reference center shift: \(variant.meanReferenceCenterShift.map { String(format: "%.3f", $0) } ?? "n/a")")
                lines.append("  direction losses: \(variant.directionLossCount)")
            }
            lines.append("Reference detection failures: \(tracking.referenceDetectionFailureCount), frame load failures: \(tracking.frameLoadFailureCount)")
            if let seconds = tracking.elapsedSeconds {
                lines.append("Elapsed: \(String(format: "%.1f", seconds))s")
            }
            lines.append("Thermally limited: \(tracking.wasThermallyLimited ? "YES" : "NO")")
            lines.append("Scope: \(tracking.scopeNote)")
        } else {
            lines.append("(not run; use the collapsed missed-detection diagnostic after confirming initial candidates)")
        }

        lines.append("")
        lines.append("=== Tracking Seed Box Diagnostic ===")
        if let seed = trackingSeedQuality {
            lines.append("Candidates: \(seed.candidateCount), center seed available: \(seed.centerSeedAvailableCount), three-frame available: \(seed.threeFrameAvailableCount)")
            lines.append("Center boxes touching crop edge: \(seed.centerEdgeTouchCount)")
            lines.append("Mean seed/search area ratio: \(seed.meanSeedToSearchAreaRatio.map { String(format: "%.3f", $0) } ?? "n/a")")
            lines.append("Mean adjacent IoU: \(seed.meanAdjacentIoU.map { String(format: "%.3f", $0) } ?? "n/a")")
            lines.append("Mean adjacent center shift: \(seed.meanAdjacentCenterShift.map { String(format: "%.3f", $0) } ?? "n/a")")
            lines.append("Mean area spread ratio: \(seed.meanAreaSpreadRatio.map { String(format: "%.2f", $0) } ?? "n/a")")
            lines.append("Stable three-frame sequences (diagnostic heuristic): \(seed.stableSequenceCount)/\(seed.threeFrameAvailableCount)")
            lines.append("Unsupported mask formats: \(seed.unsupportedMaskFormatCount), frame failures: \(seed.frameFailureCount)")
            if let seconds = seed.elapsedSeconds {
                lines.append("Elapsed: \(String(format: "%.1f", seconds))s")
            }
            lines.append("Thermally limited: \(seed.wasThermallyLimited ? "YES" : "NO")")
            lines.append("Scope: \(seed.scopeNote)")
        } else {
            lines.append("(not run; use the collapsed missed-detection diagnostic after confirming initial candidates)")
        }

        lines.append("")
        lines.append("=== Foreground Reserve Shadow Rerank ===")
        if let rerank = foregroundReserveRerank {
            lines.append("Reserve: \(rerank.reserveCount), processed: \(rerank.processedCount), mask applied: \(rerank.maskAppliedCount)")
            lines.append("Mask request failures: \(rerank.maskRequestFailureCount), baseline consistency failures: \(rerank.baselineConsistencyFailureCount), frame failures: \(rerank.frameEvaluationFailureCount)")
            lines.append("Known positives: \(rerank.knownPositiveCount), in reserve: \(rerank.knownPositiveInReserveCount)")
            lines.append("Within detail budget baseline/shadow: \(rerank.baselineWithinBudgetCount)/\(rerank.shadowWithinBudgetCount)")
            lines.append("Entered budget: \(rerank.enteredBudgetCount), left budget: \(rerank.leftBudgetCount)")
            lines.append("Known-positive ranks improved/worsened/unchanged: \(rerank.improvedRankCount)/\(rerank.worsenedRankCount)/\(rerank.unchangedRankCount)")
            if let mean = rerank.averageRankImprovement {
                lines.append("Average rank improvement (positive is better): \(String(format: "%+.2f", mean))")
            }
            if let seconds = rerank.elapsedSeconds {
                lines.append("Elapsed: \(String(format: "%.1f", seconds))s")
            }
            lines.append("Thermally limited: \(rerank.wasThermallyLimited ? "YES" : "NO")")
            lines.append("Scope: \(rerank.scopeNote)")
        } else {
            lines.append("(not run; use the collapsed missed-detection diagnostic after confirming feedback-rescan positives)")
        }

        lines.append("")
        lines.append("=== Foreground / Person Mask Diagnostic ===")
        if let mask = maskingBenchmark {
            lines.append("Reviewed initial candidates attempted: \(mask.attemptedReviewedCount)")
            if let seconds = mask.diagnosticElapsedSeconds {
                lines.append("Mask diagnostic elapsed: \(String(format: "%.1f", seconds))s")
            }
            lines.append("Thermally limited: \(mask.wasThermallyLimited ? "YES" : "NO")")
            lines.append("Foreground request failures: \(mask.foregroundRequestFailureCount)")
            lines.append("Person request failures: \(mask.personRequestFailureCount)")
            lines.append("Foreground single-instance capped candidates: \(mask.foregroundSingleTruncatedCandidateCount)")
            lines.append("Person single-instance capped candidates: \(mask.personSingleTruncatedCandidateCount)")
            for strategy in [mask.foregroundUnion, mask.foregroundBestSingle, mask.personBestSingle] {
                lines.append("\(strategy.title): paired \(strategy.availableSampleCount) (confirmed \(strategy.confirmedCount), rejected \(strategy.rejectedCount))")
                lines.append("  baseline: \(strategy.baseline.compactText)")
                lines.append("  masked: \(strategy.masked.compactText)")
                lines.append("  gap delta: \(strategy.gapDeltaText)")
            }
            lines.append("Scope: \(mask.scopeNote)")
        } else {
            lines.append("(not available; open/copy the report after reviewing initial candidates to run the diagnostic)")
        }

        lines.append("")
        lines.append("=== Scan Performance Diagnostic ===")
        if let scanPerformanceRuns, !scanPerformanceRuns.isEmpty {
            for run in scanPerformanceRuns {
                lines.append("\(run.title): total \(String(format: "%.1f", run.totalElapsedSeconds))s, thermal peak \(run.peakThermalLevel.displayName)")
                for phase in run.phases {
                    lines.append(
                        "  \(phase.phase.displayName): \(phase.elapsedText), samples=\(phase.sampleCount), \(phase.phase.outputLabel)=\(phase.outputCount), rate=\(phase.rateText), thermal=\(phase.thermalPeak.displayName)"
                    )
                }
            }
            lines.append("Timing includes manual/thermal pauses and other wall-clock waiting inside each phase.")
        } else {
            lines.append("(not available; legacy report or scan performance was not recorded)")
        }

        lines.append("")
        lines.append("=== Feedback Rescan Aggregation Diagnostic ===")
        if let benchmark = feedbackRescanAggregationBenchmark {
            lines.append("Reviewed feedback-rescan candidates: \(benchmark.sampleCount) (confirmed \(benchmark.confirmedCount), rejected \(benchmark.rejectedCount))")
            lines.append("Nearest one reference: \(benchmark.nearest.compactText)")
            lines.append("Top-2 reference mean: \(benchmark.top2Mean.compactText)")
            lines.append("Median across references: \(benchmark.median.compactText)")
            let productionMode = rescanRuns?.last?.positiveAggregationMode ?? "nearest (legacy)"
            lines.append("Scope: feedback-rescan segments only. Positive aggregation used by the latest production rescan: \(productionMode). Nearest/top-2/median are shown side by side for evaluation. Hard-negative exclusion remains nearest-positive based.")
        } else {
            lines.append("(not available; review both correct and false-positive feedback-rescan candidates)")
        }

        lines.append("")
        lines.append("=== Reference Aggregation Diagnostic ===")
        if let benchmark = referenceAggregationBenchmark {
            lines.append("Reviewed candidates with diagnostics: \(benchmark.sampleCount) (confirmed \(benchmark.confirmedCount), rejected \(benchmark.rejectedCount))")
            lines.append("Nearest one reference: \(benchmark.nearest.compactText)")
            lines.append("Top-2 reference mean: \(benchmark.top2Mean.compactText)")
            lines.append("Median across references: \(benchmark.median.compactText)")
            lines.append("Scope: \(benchmark.scopeNote)")
        } else {
            lines.append("(not available; run/review candidates created by evaluation schema 3 or later)")
        }

        lines += [
            "",
            "=== Reference Image Review ==="
        ]

        if referenceEvaluations.isEmpty {
            lines.append("(no reference evaluation)")
        } else {
            for evaluation in referenceEvaluations {
                let positive = evaluation.positiveMeanDistance.map { String(format: "%.4f", $0) } ?? "n/a"
                let negative = evaluation.negativeMeanDistance.map { String(format: "%.4f", $0) } ?? "n/a"
                lines.append(
                    "\(evaluation.label): \(evaluation.grade) | matches=\(evaluation.matchCount), confirmed=\(evaluation.confirmedCount), rejected=\(evaluation.rejectedCount), contribution=\(evaluation.contributionPercent.formatted(.percent.precision(.fractionLength(0)))), positiveMean=\(positive), negativeMean=\(negative)"
                )
                lines.append("  \(evaluation.comment)")
            }
        }

        lines.append("")
        lines.append("=== False Positive Trend ===")
        lines.append(contentsOf: falsePositiveComments.isEmpty ? ["- 判定データ不足"] : falsePositiveComments.map { "- \($0)" })

        lines.append("")
        lines.append("=== Missed Detection Trend ===")
        lines.append(contentsOf: missedDetectionComments.isEmpty ? ["- 現時点で強い見逃し傾向は確認できません。"] : missedDetectionComments.map { "- \($0)" })

        lines.append("")
        lines.append("=== Recommended Settings ===")
        lines.append("Current: sensitivity=\(currentSensitivity), coarse=\(String(format: "%.2f", currentCoarseInterval))s, detail=\(String(format: "%.2f", currentDetailInterval))s")
        lines.append("Recommended: sensitivity=\(recommendedSensitivity), coarse=\(String(format: "%.2f", recommendedCoarseInterval))s, detail=\(String(format: "%.2f", recommendedDetailInterval))s")

        lines.append("")
        lines.append("=== Guidance ===")
        lines.append(contentsOf: guidance.map { "- \($0)" })

        lines.append("")
        lines.append("Note: 『判定済み候補の正解率』は、ユーザーが正解/誤検出を付けた候補だけを母数にした指標です。動画全体に対する厳密なprecision/recallではありません。")
        lines.append("Note: temporal hit coverage は区間内サンプル時刻のFeature Printヒット率です。Visionのobject tracking精度ではありません。")
        return lines.joined(separator: "\n")
    }
}
