import SwiftUI
import UIKit

struct RecognitionReportView: View {
    let report: RecognitionQualityReport
    let combinedDiagnosticText: String
    @Environment(\.dismiss) private var dismiss
    @State private var copiedMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("総合評価") {
                    LabeledContent("対象", value: report.targetLabel.isEmpty ? "未入力" : report.targetLabel)
                    LabeledContent("レポート信頼度", value: report.reportConfidence)
                    if let engine = report.recognitionEngine {
                        LabeledContent("認識エンジン", value: engine)
                    }
                    Text(report.summaryText)
                        .font(.subheadline)
                    Text(report.videoComment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("認識結果") {
                    LabeledContent("検出区間（合計）", value: "\(report.segmentCount)")
                    LabeledContent("初回探索", value: "\(report.initialSegmentCount)")
                    LabeledContent("正解", value: "\(report.confirmedCount)")
                    LabeledContent("誤検出", value: "\(report.rejectedCount)")
                    LabeledContent("未判定", value: "\(report.unreviewedCount)")
                    LabeledContent("判定済み候補の正解率", value: report.reviewedPrecisionText)
                    if let runs = report.rescanRuns, !runs.isEmpty {
                        ForEach(runs) { run in
                            LabeledContent("再探索 #\(run.runNumber)", value: "+\(run.addedCount) / 正解 \(run.confirmedCount)")
                        }
                    }
                    LabeledContent("再探索追加（累計）", value: "\(report.rescanAddedCount)")
                    LabeledContent("再探索追加の正解（累計）", value: "\(report.rescanConfirmedCount)")
                }

                if let budget = report.candidateBudgetAnalysis {
                    Section("初回候補予算の検証") {
                        LabeledContent("詳細探索へ送った候補", value: "\(budget.initialDetailBudget)")
                        LabeledContent("分析用に保持した粗候補", value: "\(budget.initialReserveCount) / \(budget.initialReserveLimit)")
                        LabeledContent("再探索正解・初回予算内", value: "\(budget.withinInitialBudgetCount)")
                        LabeledContent("再探索正解・初回予算外", value: "\(budget.outsideInitialBudgetCount)")
                        LabeledContent("再探索正解・初回粗探索にも無し", value: "\(budget.notInInitialReserveCount)")

                        if let curve = budget.coverageCurve, !curve.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("候補数別・既知正解のrank coverage")
                                    .font(.subheadline.bold())
                                ForEach(curve) { point in
                                    let ratio = point.coverageRatio?.formatted(.percent.precision(.fractionLength(0))) ?? "n/a"
                                    Text("K=\(point.budget): \(point.coveredCount) / \(point.totalConfirmedCount)（\(ratio)）")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text("初回粗候補ランキング上で、その件数まで候補を増やした場合に再探索正解の時刻を覆えるかを見る診断です。詳細探索で実際に合格することを保証する値ではありません。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }

                        if let diversity = budget.temporalDiversity {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("時間方向の偏り診断（仮想比較）")
                                    .font(.subheadline.bold())
                                LabeledContent(
                                    "時間帯を使った数",
                                    value: "現在 \(diversity.globalOccupiedBinCount)/\(diversity.binCount) → 分散 \(diversity.timeDiverseOccupiedBinCount)/\(diversity.binCount)"
                                )
                                LabeledContent(
                                    "既知正解の時刻をカバー",
                                    value: "現在 \(diversity.globalCoveredCount) → 分散 \(diversity.timeDiverseCoveredCount) / \(diversity.knownPositiveCount)"
                                )
                                Text("『分散』は分析用reserve内の候補を、同じ候補枠数のまま動画の時間帯へ振り直した仮想比較です。本番の候補順位や認識結果は変更していません。reserve外の粗フレームは比較対象に含まれません。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }

                        Text("予算外が多い場合は、画像特徴自体だけでなく『初回に詳細探索へ送る候補数』が見逃し要因の可能性があります。初回粗探索にも無い場合は、探索間隔や画像特徴表現の影響がより疑われます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let tracking = report.objectTrackingBenchmark {
                    Section("Vision object tracking A/B") {
                        LabeledContent("対象候補", value: "\(tracking.candidateCount)")
                        LabeledContent("seed作成成功", value: "\(tracking.seededCandidateCount)")
                        LabeledContent("seed失敗", value: "\(tracking.seedFailureCount)")

                        ForEach([tracking.tight, tracking.padded], id: \.variant) { variant in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(variant.variant.displayName)
                                    .font(.subheadline.bold())
                                LabeledContent(
                                    "tracking継続",
                                    value: variant.continuationRate?.formatted(.percent.precision(.fractionLength(0))) ?? "n/a"
                                )
                                LabeledContent(
                                    "独立再検出boxとの一致",
                                    value: variant.referenceAgreementRate?.formatted(.percent.precision(.fractionLength(0))) ?? "n/a"
                                )
                                if let confidence = variant.meanConfidence {
                                    LabeledContent("平均confidence", value: String(format: "%.3f", confidence))
                                }
                                if let iou = variant.meanReferenceIoU {
                                    LabeledContent("参照box平均IoU", value: String(format: "%.3f", iou))
                                }
                                if let shift = variant.meanReferenceCenterShift {
                                    LabeledContent("参照box平均中心差", value: String(format: "%.3f", shift))
                                }
                                LabeledContent("方向単位のtracking欠損", value: "\(variant.directionLossCount)")
                                Text("attempted \(variant.attemptedFrameCount) / tracked \(variant.trackedFrameCount) / comparable \(variant.comparableFrameCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }

                        LabeledContent("参照box再検出失敗", value: "\(tracking.referenceDetectionFailureCount)")
                        LabeledContent("フレーム読込失敗", value: "\(tracking.frameLoadFailureCount)")
                        if let seconds = tracking.elapsedSeconds {
                            LabeledContent("診断時間", value: String(format: "%.1f秒", seconds))
                        }
                        if tracking.wasThermallyLimited {
                            Label("端末温度により途中で制限しました。", systemImage: "thermometer.high")
                                .font(.caption)
                        }
                        Text("独立再検出boxはground truthではありません。trackerが別の似た対象へ移った場合だけでなく、foreground再検出側が別対象へ切り替わった場合も一致率は低下します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(tracking.scopeNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let seed = report.trackingSeedQuality {
                    Section("tracking seed box診断") {
                        LabeledContent("対象候補", value: "\(seed.candidateCount)")
                        LabeledContent("中心box取得", value: "\(seed.centerSeedAvailableCount)")
                        LabeledContent("前・中央・後の3時刻取得", value: "\(seed.threeFrameAvailableCount)")
                        LabeledContent("安定3時刻シーケンス", value: "\(seed.stableSequenceCount)")
                        LabeledContent("中心boxが検索窓端に接触", value: "\(seed.centerEdgeTouchCount)")
                        if let value = seed.meanSeedToSearchAreaRatio {
                            LabeledContent("平均box/検索窓面積比", value: String(format: "%.3f", value))
                        }
                        if let value = seed.meanAdjacentIoU {
                            LabeledContent("隣接box平均IoU", value: String(format: "%.3f", value))
                        }
                        if let value = seed.meanAdjacentCenterShift {
                            LabeledContent("隣接box平均中心移動", value: String(format: "%.3f", value))
                        }
                        if let value = seed.meanAreaSpreadRatio {
                            LabeledContent("3時刻の平均面積変動比", value: String(format: "%.2f×", value))
                        }
                        LabeledContent("未対応mask形式", value: "\(seed.unsupportedMaskFormatCount)")
                        LabeledContent("フレーム評価失敗", value: "\(seed.frameFailureCount)")
                        if let seconds = seed.elapsedSeconds {
                            LabeledContent("診断時間", value: String(format: "%.1f秒", seconds))
                        }
                        if seed.wasThermallyLimited {
                            Label("端末温度により途中で制限しました。", systemImage: "thermometer.high")
                                .font(.caption)
                        }
                        Text("安定シーケンスは診断用ヒューリスティック（隣接IoU 0.25以上、中心移動0.20以下、面積最大/最小3倍以下）であり、VNTrackObjectRequestの成功率ではありません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(seed.scopeNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let rerank = report.foregroundReserveRerank {
                    Section("前景mask・初回候補再順位") {
                        LabeledContent("analysis reserve", value: "\(rerank.reserveCount)")
                        LabeledContent("処理済み", value: "\(rerank.processedCount)")
                        LabeledContent("mask適用", value: "\(rerank.maskAppliedCount)")
                        LabeledContent("baseline再現不一致", value: "\(rerank.baselineConsistencyFailureCount)")
                        LabeledContent("フレーム評価失敗", value: "\(rerank.frameEvaluationFailureCount)")
                        LabeledContent("mask API失敗", value: "\(rerank.maskRequestFailureCount)")
                        LabeledContent("既知正解", value: "\(rerank.knownPositiveCount)")
                        LabeledContent("reserve内の既知正解", value: "\(rerank.knownPositiveInReserveCount)")
                        LabeledContent(
                            "詳細予算内",
                            value: "現在 \(rerank.baselineWithinBudgetCount) → mask再順位 \(rerank.shadowWithinBudgetCount)"
                        )
                        LabeledContent(
                            "予算境界を越えた正解",
                            value: "上昇 \(rerank.enteredBudgetCount) / 下降 \(rerank.leftBudgetCount)"
                        )
                        LabeledContent(
                            "順位変化",
                            value: "改善 \(rerank.improvedRankCount) / 悪化 \(rerank.worsenedRankCount) / 同じ \(rerank.unchangedRankCount)"
                        )
                        if let mean = rerank.averageRankImprovement {
                            LabeledContent(
                                "平均順位改善",
                                value: String(format: "%+.2f", mean)
                            )
                        }
                        if let seconds = rerank.elapsedSeconds {
                            LabeledContent("診断時間", value: String(format: "%.1f秒", seconds))
                        }
                        if rerank.wasThermallyLimited {
                            Label("端末温度により途中で制限しました。未処理候補は元distanceへfallbackしています。", systemImage: "thermometer.high")
                                .font(.caption)
                        }
                        Text(rerank.scopeNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let mask = report.maskingBenchmark {
                    Section("背景・周辺対象の影響診断") {
                        LabeledContent("診断した判定済み候補", value: "\(mask.attemptedReviewedCount)")
                        if let seconds = mask.diagnosticElapsedSeconds {
                            LabeledContent("mask診断の累計時間", value: String(format: "%.1f秒", seconds))
                        }
                        if mask.wasThermallyLimited {
                            Label("端末温度により診断を途中で制限しました。次回レポート表示時に未計算分を続行します。", systemImage: "thermometer.high")
                                .font(.caption)
                        }
                        LabeledContent("前景mask API失敗", value: "\(mask.foregroundRequestFailureCount)")
                        LabeledContent("人物mask API失敗", value: "\(mask.personRequestFailureCount)")
                        if mask.foregroundSingleTruncatedCandidateCount > 0 {
                            LabeledContent("前景instance上限対象", value: "\(mask.foregroundSingleTruncatedCandidateCount)")
                        }
                        if mask.personSingleTruncatedCandidateCount > 0 {
                            LabeledContent("人物instance上限対象", value: "\(mask.personSingleTruncatedCandidateCount)")
                        }

                        ForEach(
                            [mask.foregroundUnion, mask.foregroundBestSingle, mask.personBestSingle],
                            id: \.title
                        ) { strategy in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(strategy.title)
                                    .font(.subheadline.bold())
                                Text("paired \(strategy.availableSampleCount)（正解 \(strategy.confirmedCount) / 誤検出 \(strategy.rejectedCount)）")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("元画像: \(strategy.baseline.compactText)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("mask後: \(strategy.masked.compactText)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("gap改善量: \(strategy.gapDeltaText)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }

                        Text(mask.scopeNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("前景全体は背景だけの影響、単一instance最良は背景＋周辺対象の分離余地を見る診断です。mask前後で画角・対象サイズは変えません。単一instanceは最大8個まで比較します。人物maskは人物として認識できた候補だけが対象で、着ぐるみ・キャラクターでは利用できない場合があります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let performanceRuns = report.scanPerformanceRuns, !performanceRuns.isEmpty {
                    Section("処理性能の診断") {
                        ForEach(performanceRuns) { run in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(run.title)
                                    .font(.subheadline.bold())
                                LabeledContent(
                                    "合計経過",
                                    value: String(format: "%.1f秒", run.totalElapsedSeconds)
                                )
                                LabeledContent(
                                    "最高温度状態",
                                    value: run.peakThermalLevel.displayName
                                )
                                ForEach(Array(run.phases.enumerated()), id: \.offset) { _, phase in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(phase.phase.displayName)
                                            .font(.caption.bold())
                                        Text("\(phase.elapsedText) / \(phase.sampleCount) samples / \(phase.phase.outputLabel) \(phase.outputCount) / \(phase.rateText) / 温度 \(phase.thermalPeak.displayName)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        Text("経過時間は実測の壁時計時間で、手動一時停止・温度抑制・自動停止中の待機を含みます。認識結果を変える計測ではありません。復旧解析は復旧位置以降だけを計測します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let benchmark = report.feedbackRescanAggregationBenchmark {
                    Section("学習再探索・見本集約A/B") {
                        LabeledContent("判定済み再探索候補", value: "\(benchmark.sampleCount)")
                        if let precision = report.rescanReviewedPrecision {
                            LabeledContent(
                                "再探索の正解率",
                                value: precision.formatted(.percent.precision(.fractionLength(0)))
                            )
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最近傍1枚")
                                .font(.subheadline.bold())
                            Text(benchmark.nearest.compactText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上位2見本の平均")
                                .font(.subheadline.bold())
                            Text(benchmark.top2Mean.compactText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("見本間の中央値")
                                .font(.subheadline.bold())
                            Text(benchmark.median.compactText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("学習再探索で追加され、○/×判定済みの候補だけを比較します。元見本＋学習見本＋hard negativeという再探索時の条件での診断です。本番の候補採否はまだ変更しません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let benchmark = report.referenceAggregationBenchmark {
                    Section("見本集約方式のA/B診断") {
                        LabeledContent("判定済みサンプル", value: "\(benchmark.sampleCount)")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最近傍1枚")
                                .font(.subheadline.bold())
                            Text(benchmark.nearest.compactText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上位2見本の平均")
                                .font(.subheadline.bold())
                            Text(benchmark.top2Mean.compactText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("見本間の中央値")
                                .font(.subheadline.bold())
                            Text(benchmark.median.compactText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(benchmark.scopeNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("参考画像の短評") {
                    if report.referenceEvaluations.isEmpty {
                        Text("参考画像を選択すると評価できます。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(report.referenceEvaluations) { evaluation in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(evaluation.label)
                                        .font(.headline)
                                    Spacer()
                                    Text(evaluation.grade)
                                        .font(.caption.bold())
                                }
                                Text(evaluation.comment)
                                    .font(.subheadline)
                                Text("正解 \(evaluation.confirmedCount) / 誤検出 \(evaluation.rejectedCount) / 寄与 \(evaluation.contributionPercent.formatted(.percent.precision(.fractionLength(0))))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section("誤検出傾向") {
                    ForEach(report.falsePositiveComments, id: \.self) { comment in
                        Label(comment, systemImage: "xmark.circle")
                            .font(.subheadline)
                    }
                    if report.falsePositiveComments.isEmpty {
                        Text("判定データがまだ十分ではありません。")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("見逃し傾向") {
                    ForEach(report.missedDetectionComments, id: \.self) { comment in
                        Label(comment, systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.subheadline)
                    }
                    if report.missedDetectionComments.isEmpty {
                        Text("現時点で強い見逃し傾向は確認できません。")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("次回推奨設定") {
                    LabeledContent("感度", value: report.recommendedSensitivity)
                    LabeledContent("粗探索", value: String(format: "%.2f秒", report.recommendedCoarseInterval))
                    LabeledContent("詳細探索", value: String(format: "%.2f秒", report.recommendedDetailInterval))
                    ForEach(report.guidance, id: \.self) { item in
                        Text("• \(item)")
                            .font(.subheadline)
                    }
                }

                Section("共有") {
                    Button {
                        UIPasteboard.general.string = report.textReport
                        copiedMessage = "精度レポートをコピーしました。"
                    } label: {
                        Label("精度レポートをコピー", systemImage: "doc.on.doc")
                    }

                    Button {
                        UIPasteboard.general.string = combinedDiagnosticText
                        copiedMessage = "診断＋精度レポートをコピーしました。"
                    } label: {
                        Label("診断＋精度レポートをコピー", systemImage: "doc.on.doc.fill")
                    }

                    if let copiedMessage {
                        Text(copiedMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("正解率は、判定済み候補だけを母数にした実用上の指標です。動画全体の厳密なprecision/recallではありません。見逃し評価は、学習再探索で新しく見つかり、その後『正解』になった区間を主な手掛かりにしています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("認識精度レポート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
