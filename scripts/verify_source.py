#!/usr/bin/env python3
from pathlib import Path
import re

ROOT_ALLOWED = {".github", ".gitignore", "README.md", "VideoTargetFinder", "docs", "project.yml", "scripts"}
root_names = {p.name for p in Path(".").iterdir() if p.name != ".git"}
extra = sorted(root_names - ROOT_ALLOWED)
assert not extra, f"Unexpected repository-root entries: {extra}"

for p in Path(".").rglob("*"):
    if ".git" in p.parts:
        continue
    name = p.name.lower()
    assert not name.endswith(".ipa"), f"IPA must not be committed: {p}"
    assert "build-device" not in p.parts and "build-simulator" not in p.parts, f"Build output committed: {p}"
    assert not ("stage" in name and ("patch" in name or name.endswith(".zip"))), f"Legacy stage artifact committed: {p}"

project = Path("project.yml").read_text(encoding="utf-8")
assert re.search(r"MARKETING_VERSION:\s*0\.28\.0", project), "Version 0.28.0 missing"
assert re.search(r"CURRENT_PROJECT_VERSION:\s*30", project), "Build 30 missing"
assert "jp.inari1234.videotargetfinder" in project, "Bundle ID mismatch"
assert "UIFileSharingEnabled: true" in project, "File Sharing must stay enabled"
assert "LSSupportsOpeningDocumentsInPlace: true" in project, "Open-in-place must stay enabled"
assert "path: VideoTargetFinder/Info.plist" in project, "XcodeGen Info.plist generation must stay explicit"

swift = "\n".join(p.read_text(encoding="utf-8") for p in Path("VideoTargetFinder").glob("*.swift"))
for banned in ("creationRequestForAssetFromVideo", "PHAssetCreationRequest", "PHPhotoLibrary.shared().performChanges", "requestAVAsset(forVideo"):
    assert banned not in swift, f"Banned crash-prone path returned: {banned}"
assert "requestPlayerItem(forVideo:" in swift, "Stable requestPlayerItem video-loading path missing"
assert "PendingExportStore.makeOutputURL" in swift, "Safe app-internal export persistence missing"
assert "ShareLink(item: url)" in swift, "Share-sheet save path missing"

content = Path("VideoTargetFinder/ContentView.swift").read_text(encoding="utf-8")
for title in ('GroupBox("1. 解析する動画")', 'GroupBox("2. 探したい対象の見本画像（最大5枚）")', 'GroupBox("3. 推しを探す")', 'GroupBox("4. 候補を確認")', 'GroupBox("5. 推し動画を作る")'):
    assert title in content, f"Five-step main flow missing: {title}"
assert 'GroupBox("6.' not in content and 'GroupBox("7.' not in content and 'GroupBox("8.' not in content, "Old numbered flow remains"
assert "自動候補しきい値:" not in content, "Threshold leaked back into main scan card"
for disclosure in ('DisclosureGroup("候補の詳細")', 'DisclosureGroup("切り出し・判定の詳細調整")', 'DisclosureGroup("再探索の詳細")', 'DisclosureGroup("書き出しの詳細設定")'):
    assert disclosure in content, f"Collapsed technical UI missing: {disclosure}"

report = Path("VideoTargetFinder/RecognitionQualityReport.swift").read_text(encoding="utf-8")
view_model = Path("VideoTargetFinder/VideoAnalysisViewModel.swift").read_text(encoding="utf-8")
assert "FeedbackRescanRunSummary" in report, "Per-rescan report model missing"
assert "rescanRuns: [FeedbackRescanRunSummary]?" in report, "Backward-compatible rescan history missing"
assert "feedbackRescanRuns" in view_model, "Runtime rescan history missing"
assert "Feedback-rescan total added" in report, "Cumulative rescan label missing"
assert "Feedback-rescan history" in report, "Per-run rescan history output missing"

candidate_budget = Path("VideoTargetFinder/CandidateBudgetAnalyzer.swift").read_text(encoding="utf-8")
assert "CandidateBudgetAttribution" in candidate_budget, "Candidate budget attribution model missing"
assert "rankCoveringSegment" in candidate_budget, "Candidate budget rank analyzer missing"
assert Path("scripts/test_candidate_budget.swift").exists(), "Candidate budget unit test missing"
assert "analysisReserveLimit: analysisReserveLimit" in view_model, "Lightweight analysis reserve must be collected during initial coarse scan"
assert "candidateLimit: analysisReserveLimit" not in view_model, "Analysis reserve must not enlarge the normal ScanCandidate list"
assert "CandidateBudgetAnalyzer.insertDistinct" in view_model, "Lightweight reserve ranking must use the tested analyzer"

pipeline_core = Path("VideoTargetFinder/ScanPipelineCore.swift").read_text(encoding="utf-8")
pipeline_core_test = Path("scripts/test_scan_pipeline_core.swift").read_text(encoding="utf-8")
video_pipeline_test = Path("scripts/test_video_pipeline_runtime.swift").read_text(encoding="utf-8")
assert "ScanPipelineCore.insertDistinct(" in view_model, "Production candidate ranking must use ScanPipelineCore"
assert "ScanPipelineCore.percentile(" in view_model, "Production threshold must use ScanPipelineCore"
assert "ScanPipelineCore.mergedDetailWindows(" in view_model, "Production detail windows must use ScanPipelineCore"
assert "ScanPipelineCore.segmentPlans(" in view_model, "Production segment grouping must use ScanPipelineCore"
assert "ScanPipelineCore tests: PASS" in pipeline_core_test, "ScanPipelineCore unit test marker missing"
assert "Headless coarse/detail/segment replay: PASS" in video_pipeline_test, "Headless production replay marker missing"
assert "initialAnalysisReserve: restoredAnalysisReserve" in view_model, "Checkpoint recovery must restore the lightweight analysis reserve"
assert "version: 2" in view_model, "Checkpoint version 2 required for expanded reserve provenance"
assert 'recognitionEngine: "Apple Vision Feature Print"' in view_model, "Evaluation report engine label missing"
assert "candidateBudgetAnalysis: candidateBudgetAnalysis" in view_model, "Candidate budget analysis missing from report"

checkpoint = Path("VideoTargetFinder/ScanCheckpointStore.swift").read_text(encoding="utf-8")
assert "analysisReserve: [PersistedCandidateBudgetPoint]?" in checkpoint, "Checkpoint must persist the lightweight reserve separately"


storage_layout = Path("VideoTargetFinder/PersistentStorageLayout.swift").read_text(encoding="utf-8")
checkpoint_store = Path("VideoTargetFinder/ScanCheckpointStore.swift").read_text(encoding="utf-8")
report_store = Path("VideoTargetFinder/RecognitionReportSnapshotStore.swift").read_text(encoding="utf-8")
diagnostic_logger = Path("VideoTargetFinder/DiagnosticLogger.swift").read_text(encoding="utf-8")
assert Path("scripts/test_persistent_storage_layout.swift").exists(), "Persistent storage regression test missing"
assert "clearScanCheckpoint" in storage_layout, "Checkpoint-scoped clear helper missing"
assert "removeItem(at: rootURL)" not in checkpoint_store, "Checkpoint clear must never delete the shared Application Support root"
assert "PersistentStorageLayout.clearScanCheckpoint" in checkpoint_store, "Checkpoint store must use scoped deletion"
assert "PersistentStorageLayout.recognitionReportURL" in report_store, "Recognition report path must use shared storage layout"
assert "PersistentStorageLayout.diagnosticLogURL" in diagnostic_logger, "Diagnostic log path must use shared storage layout"

assert "prefixMatches" in candidate_budget, "Candidate/reserve prefix consistency validator missing"
assert "reservePrefixVerified" in view_model, "Runtime candidate/reserve consistency check missing"
assert "initialCoarseReserveAnalysisAvailable = reservePrefixVerified" in view_model, "Fresh scan must disable budget attribution when prefix validation fails"
assert "checkpoint.analysisReserve != nil && reservePrefixVerified" in view_model, "Recovered scan must require saved reserve plus prefix validation"


# v0.20.2: selection changes must invalidate only the matching scan checkpoint,
# while a failed replacement-video load must preserve the existing recoverable scan.
load_start = view_model.index("func loadVideo(from result: PHPickerResult)")
load_end = view_model.index("func setReferenceImages", load_start)
load_block = view_model[load_start:load_end]
metadata_marker = 'DiagnosticLogger.log("Video load step 3: metadata loaded")'
assert metadata_marker in load_block, "Video-load success marker missing"
assert "ScanCheckpointStore.clear()" in load_block[load_block.index(metadata_marker):], "Checkpoint must clear only after replacement video loads successfully"
assert "ScanCheckpointStore.clear()" not in load_block[:load_block.index(metadata_marker)], "Failed replacement-video selection must preserve recoverable checkpoint"

remove_start = view_model.index("func removeReferenceImage")
remove_end = view_model.index("func setError", remove_start)
remove_block = view_model[remove_start:remove_end]
assert "ScanCheckpointStore.clear()" in remove_block, "Removing a reference image must invalidate the stale checkpoint"
assert "hasRecoverableScan = false" in remove_block, "Reference removal must clear recoverable-scan UI state"
assert "checkpointReferencesWritten = false" in remove_block, "Reference removal must reset checkpoint reference persistence state"

assert 'Text("連続検出: \\(segment.hitCount)ヒット / ヒット率 \\(segment.trackingText)")' in content, "Temporal hit coverage UI label missing"
assert 'Text("追跡:' not in content, "Misleading object-tracking UI label returned"
assert "Average temporal hit coverage:" in report, "Recognition report must distinguish temporal hit coverage from object tracking"
assert "Visionのobject tracking精度ではありません" in report, "Recognition report must document temporal hit coverage semantics"


# v0.21: reference aggregation A/B is diagnostics-only and must not change production acceptance.
aggregation = Path("VideoTargetFinder/ReferenceScoreAnalyzer.swift").read_text(encoding="utf-8")
detected_segment = Path("VideoTargetFinder/DetectedSegment.swift").read_text(encoding="utf-8")
matcher = Path("VideoTargetFinder/FeaturePrintMatcher.swift").read_text(encoding="utf-8")
report_view = Path("VideoTargetFinder/RecognitionReportView.swift").read_text(encoding="utf-8")
assert Path("scripts/test_reference_score_analyzer.swift").exists(), "Reference aggregation unit test missing"
assert "top2Mean" in aggregation and "median" in aggregation, "Reference aggregation strategies missing"
assert "aggregationScores: ReferenceAggregationScores" in matcher, "Matcher diagnostic scores missing"
assert "aggregationScores: match.aggregationScores" in view_model, "Detailed-hit aggregation diagnostics missing"
assert "aggregationScores: diagnosticScores" in view_model, "Segment aggregation diagnostics missing"
assert "referenceAggregationBenchmark: aggregationBenchmark" in view_model, "Recognition report aggregation benchmark missing"
assert "evaluationSchemaVersion: 9" in view_model, "Evaluation schema 9 required"
assert "見本集約方式のA/B診断" in report_view, "Aggregation benchmark UI section missing"
assert "match.distance <= threshold" in view_model, "Production detailed acceptance must still use current nearest Feature Print distance"
assert "distance: positiveDistance" in matcher, "Production RegionMatch distance must remain nearest positive distance"


# v0.21 benchmark fairness: do not mix feedback-rescan distances scored with learned references/hard negatives.
benchmark_start = view_model.index("private func makeReferenceAggregationBenchmark")
benchmark_end = view_model.index("private func makeCandidateBudgetAnalysis", benchmark_start)
benchmark_block = view_model[benchmark_start:benchmark_end]
assert "segment.discoverySource == .initial" in benchmark_block, "Aggregation A/B must compare only initial-scan segments scored with the same reference set"


# v0.21 benchmark independence: alternate aggregators choose their own best crop/time inside production-admitted evidence.
assert "acceptedAggregationSamples" in matcher, "Aggregation diagnostics must compare across accepted frame regions"
assert "ReferenceScoreAnalyzer.bestAcrossSamples(acceptedAggregationSamples)" in matcher, "Each aggregation strategy must be free to choose its best region"
assert "group.map(\\.aggregationScores)" in view_model, "Segment benchmark must aggregate diagnostics across detailed hits, not only production best hit"


# v0.22: candidate-budget coverage and temporal-diversity diagnostics are report-only.
assert "let coverageCurve: [CandidateBudgetCoveragePoint]?" in candidate_budget, "Backward-compatible optional budget coverage curve missing"
assert "let temporalDiversity: CandidateTemporalDiversitySummary?" in candidate_budget, "Backward-compatible optional temporal diversity summary missing"
assert "coverageCurve(" in candidate_budget, "Budget coverage curve analyzer missing"
assert "timeDiverseSelection(" in candidate_budget, "Temporal diversity benchmark missing"
assert "CandidateBudgetAnalyzer.coverageCurve" in view_model, "Runtime budget coverage diagnostic missing"
assert "CandidateBudgetAnalyzer.temporalDiversitySummary" in view_model, "Runtime temporal diversity diagnostic missing"
budget_analysis_start = view_model.index("private func makeCandidateBudgetAnalysis")
budget_analysis_end = view_model.index("func recognitionQualityReportText", budget_analysis_start)
budget_analysis_block = view_model[budget_analysis_start:budget_analysis_end]
assert "CandidateBudgetAnalyzer.temporalDiversitySummary" in budget_analysis_block, "Time-diverse selection must stay inside report analysis"
coarse_start = view_model.index("private func runCoarseScan")
coarse_end = view_model.index("private func runDetailedScan", coarse_start)
coarse_block = view_model[coarse_start:coarse_end]
assert "timeDiverseSelection" not in coarse_block, "Temporal diversity benchmark must not alter production coarse candidate selection"


# v0.22 UI must label rank coverage and time diversity as diagnostics, not production behavior.
report_view = Path("VideoTargetFinder/RecognitionReportView.swift").read_text(encoding="utf-8")
assert "候補数別・既知正解のrank coverage" in report_view, "Budget coverage UI missing"
assert "時間方向の偏り診断（仮想比較）" in report_view, "Temporal diversity diagnostic UI missing"
assert "本番の候補順位や認識結果は変更していません" in report_view, "Temporal diversity UI must disclose diagnostic-only behavior"

assert "reserve外の粗フレームは比較対象に含まれません" in report_view, "Temporal diversity UI must disclose reserve-only scope"


# v0.23: performance diagnostics must measure around production scans without changing scan algorithms.
performance = Path("VideoTargetFinder/ScanPerformanceDiagnostics.swift").read_text(encoding="utf-8")
report_view = Path("VideoTargetFinder/RecognitionReportView.swift").read_text(encoding="utf-8")
assert Path("scripts/test_scan_performance.swift").exists(), "Scan performance unit test missing"
assert "ScanPerformanceRunSummary" in performance, "Scan performance run model missing"
assert "ScanPhasePerformanceSummary" in performance, "Scan performance phase model missing"
assert "let scanPerformanceRuns: [ScanPerformanceRunSummary]?" in report, "Backward-compatible optional scan performance report field missing"
assert "scanPerformanceRuns: scanPerformanceRuns.isEmpty ? nil : scanPerformanceRuns" in view_model, "Runtime scan performance report integration missing"
assert "beginPerformancePhase()" in view_model and "finishPerformancePhase(" in view_model, "Phase timing instrumentation missing"
assert "recordPerformanceRun(kind: .initial" in view_model, "Initial scan performance recording missing"
assert "kind: .feedbackRescan" in view_model, "Feedback rescan performance recording missing"
assert "recordPerformanceRun(kind: .recovery" in view_model, "Recovery performance recording missing"
assert "処理性能の診断" in report_view, "Performance diagnostic UI missing"
assert "手動一時停止・温度抑制・自動停止中の待機を含みます" in report_view, "Wall-clock timing scope disclosure missing"
assert "復旧解析は復旧位置以降だけを計測します" in report_view, "Recovery timing scope disclosure missing"

coarse_start = view_model.index("private func runCoarseScan")
coarse_end = view_model.index("private func runDetailedScan", coarse_start)
coarse_block = view_model[coarse_start:coarse_end]
detail_start = view_model.index("private func runDetailedScan")
detail_end = view_model.index("private func buildSegments", detail_start)
detail_block = view_model[detail_start:detail_end]
assert "ScanPerformance" not in coarse_block, "Performance diagnostics must not alter runCoarseScan selection logic"
assert "ScanPerformance" not in detail_block, "Performance diagnostics must not alter runDetailedScan matching logic"

assert "候補の連続追跡率" not in view_model, "Legacy tracking-rate wording returned"
assert "詳細しきい値・追跡・区間化側" not in view_model, "Legacy tracking wording returned in missed-detection analysis"


# v0.23 detailed-scan progress denominator must match the actual while-loop sample count.
assert "static func detailSampleCount(" in performance, "Exact detailed sample counter definition missing"
assert "ScanPerformanceAnalyzer.detailSampleCount" in view_model, "Detailed sample counter must be used by the runtime helper"
assert "ScanPerformanceAnalyzer.detailSampleCount" in Path("scripts/test_scan_performance.swift").read_text(encoding="utf-8"), "Detailed sample counter unit coverage missing"
assert "let totalSamples = max(1, detailSampleCount(windows: windows, interval: interval))" in detail_block, "Detailed scan progress must use the shared exact sample count"
assert "ceil(($0.end - $0.start) / interval)" not in detail_block, "Old over-counting detailed progress formula returned"


# v0.24: foreground/person mask diagnostics are on-demand, paired, and disconnected from production scan selection.
masking = Path("VideoTargetFinder/MaskingDiagnostics.swift").read_text(encoding="utf-8")
mask_engine = Path("VideoTargetFinder/VisionMaskDiagnosticEngine.swift").read_text(encoding="utf-8")
content_view = Path("VideoTargetFinder/ContentView.swift").read_text(encoding="utf-8")
report_view = Path("VideoTargetFinder/RecognitionReportView.swift").read_text(encoding="utf-8")
assert Path("scripts/test_masking_diagnostics.swift").exists(), "Masking diagnostic unit test missing"
assert "MaskingBenchmarkSummary" in masking, "Masking benchmark model missing"
assert "foregroundUnion" in masking and "foregroundBestSingle" in masking and "personBestSingle" in masking, "Mask strategies missing"
assert "VNGenerateForegroundInstanceMaskRequest" in mask_engine, "Foreground instance-mask request missing"
assert "VNGeneratePersonInstanceMaskRequest" in mask_engine, "Person instance-mask request missing"
assert "generateMaskedImage" in mask_engine, "High-resolution masked-image generation missing"
assert "diagnosticPositiveDistance" in matcher, "Diagnostics-only direct Feature Print score missing"
assert "func prepareMaskingDiagnosticsIfNeeded() async" in view_model, "On-demand mask diagnostic preparation missing"
assert "$0.discoverySource == .initial" in view_model, "Mask diagnostics must exclude feedback-rescan segments"
assert "$0.reviewState != .unreviewed" in view_model, "Mask diagnostics must run only for reviewed candidates"
assert "maskDiagnosticsBySegmentID[$0.id] == nil" in view_model, "Mask diagnostics must cache and skip completed candidates"
assert "maskingBenchmark: maskingBenchmark" in view_model, "Mask benchmark missing from report"
assert "let maskingBenchmark: MaskingBenchmarkSummary?" in report, "Backward-compatible optional mask benchmark field missing"
assert "背景・周辺対象の影響診断" in report_view, "Mask diagnostic report UI missing"
assert "await viewModel.prepareMaskingDiagnosticsIfNeeded()" in content_view, "Opening/copying report must prepare missing mask diagnostics"
assert "背景影響を診断中" in content_view, "Mask diagnostic progress label missing"
assert "maskで新しい未検出場面を拾えるかというrecallは評価しません" in masking, "Mask diagnostic scope limitation missing"

coarse_start = view_model.index("private func runCoarseScan")
coarse_end = view_model.index("private func runDetailedScan", coarse_start)
coarse_block = view_model[coarse_start:coarse_end]
detail_start = view_model.index("private func runDetailedScan")
detail_end = view_model.index("private func buildSegments", detail_start)
detail_block = view_model[detail_start:detail_end]
assert "VisionMaskDiagnosticEngine" not in coarse_block, "Mask diagnostics must not alter coarse scan"
assert "VisionMaskDiagnosticEngine" not in detail_block, "Mask diagnostics must not alter detailed scan"
assert "diagnosticPositiveDistance" not in coarse_block and "diagnosticPositiveDistance" not in detail_block, "Direct diagnostic score must not affect production scan"

assert "croppedToInstancesExtent: false" in mask_engine, "Mask A/B must preserve original geometry and avoid crop/scale confounding"
assert "croppedToInstancesExtent: true" not in mask_engine, "Auto-cropping masked instances would confound background-removal A/B"
assert "foregroundSingleTruncatedCandidateCount" in masking and "personSingleTruncatedCandidateCount" in masking, "Single-instance cap visibility missing"
assert "maskDiagnosticTotalElapsedSeconds += max(0, Date().timeIntervalSince(startedAt))\n            persistRecognitionReportSnapshot" in view_model, "Saved report must include current mask diagnostic elapsed time"

assert "let ciContext = CIContext()" in mask_engine, "Mask diagnostic must reuse a CIContext per candidate"
assert "CIContext().createCGImage" not in mask_engine, "Creating a CIContext for every mask variant is too expensive"
assert "maskDiagnosticWasThermallyLimited" in view_model, "Mask diagnostic thermal-limit state missing"
assert "case .critical:" in view_model[view_model.index("func prepareMaskingDiagnosticsIfNeeded"):view_model.index("func recognitionQualityReportForDisplay")], "Mask diagnostics must stop on critical thermal state"
assert "try await Task.sleep(for: .milliseconds(220))" in view_model[view_model.index("func prepareMaskingDiagnosticsIfNeeded"):view_model.index("func recognitionQualityReportForDisplay")], "Mask diagnostics must throttle on serious thermal state"
assert "wasThermallyLimited" in masking, "Mask benchmark must disclose thermal truncation"


# v0.25: foreground-mask shadow reranking must stay inside the saved analysis reserve and outside production scans.
rerank = Path("VideoTargetFinder/ForegroundReserveRerankDiagnostics.swift").read_text(encoding="utf-8")
rerank_test = Path("scripts/test_foreground_reserve_rerank.swift").read_text(encoding="utf-8")
assert "ForegroundReserveRerankSummary" in rerank, "Foreground reserve rerank summary missing"
assert "baselineIsConsistent" in rerank, "Refetched-frame baseline consistency guard missing"
assert "shadowDistance" in rerank, "Shadow fallback distance missing"
assert "maskで別regionを選ぶ可能性" in rerank, "Shadow rerank scope limitation missing"
assert "foregroundUnionDistance(" in mask_engine, "Lightweight foreground-union shadow scorer missing"
assert "func startForegroundReserveRerankDiagnostic()" in view_model, "Foreground reserve rerank runtime entry missing"
assert "initialCoarseReserve" in view_model[view_model.index("func startForegroundReserveRerankDiagnostic"):view_model.index("func cancelForegroundReserveRerankDiagnostic")], "Shadow rerank must use initial analysis reserve"
assert "initialScanSensitivity" in view_model, "Initial production sensitivity provenance missing"
assert "makeExactDiagnosticImageGenerator" in view_model, "Exact-time diagnostic image generator missing"
assert "foregroundReserveRerank: foregroundReserveRerankSummary" in view_model, "Shadow rerank missing from report"
assert "let foregroundReserveRerank: ForegroundReserveRerankSummary?" in report, "Backward-compatible optional shadow rerank report field missing"
assert "見逃し診断の詳細" in content_view, "Collapsed shadow rerank control missing"
assert "前景mask・初回候補再順位" in report_view, "Shadow rerank report section missing"
assert "通常の候補順位や認識結果は変更しません" in content_view, "Shadow rerank UI must disclose diagnostic-only behavior"
assert "ForegroundReserveRerankDiagnostics tests: PASS" in rerank_test, "Shadow rerank unit test marker missing"

coarse_start = view_model.index("private func runCoarseScan")
coarse_end = view_model.index("private func runDetailedScan", coarse_start)
coarse_block = view_model[coarse_start:coarse_end]
detail_start = view_model.index("private func runDetailedScan")
detail_end = view_model.index("private func buildSegments", detail_start)
detail_block = view_model[detail_start:detail_end]
assert "foregroundUnionDistance" not in coarse_block, "Foreground shadow scorer must not alter production coarse scan"
assert "foregroundUnionDistance" not in detail_block, "Foreground shadow scorer must not alter production detail scan"
assert "ForegroundReserveRerankAnalyzer" not in coarse_block and "ForegroundReserveRerankAnalyzer" not in detail_block, "Shadow reranking must not alter production scanning"

assert "guard wasProcessed, baselineConsistent, let maskedDistance" in rerank, "Unprocessed shadow candidates must always fall back to baseline distance"


# v0.26: foreground-instance tracking seed box diagnostics remain diagnostic-only.
tracking_seed = Path("VideoTargetFinder/TrackingSeedBoxDiagnostics.swift").read_text(encoding="utf-8")
tracking_seed_test = Path("scripts/test_tracking_seed_box.swift").read_text(encoding="utf-8")
assert "TrackingSeedQualitySummary" in tracking_seed, "Tracking seed quality summary missing"
assert "tightBoxes(" in tracking_seed, "Instance label-mask tight-box extraction missing"
assert "mapLocalTopLeftRectToVision" in tracking_seed, "Top-left mask to Vision lower-left coordinate conversion missing"
assert "intersectionOverUnion" in tracking_seed and "centerShift" in tracking_seed, "Tracking-seed stability metrics missing"
assert "offsetSeconds <= -0.15" in tracking_seed and "offsetSeconds >= 0.15" in tracking_seed, "Distinct pre/post sample guard missing"
assert "bestForegroundTrackingSeed(" in mask_engine, "Foreground tracking-seed extraction missing"
assert "observation.instanceMask" in mask_engine, "Tracking seed must derive boxes from the instance label mask"
assert "kCVPixelFormatType_OneComponent8" in mask_engine, "Instance mask 8-bit label-buffer support missing"
assert "kCVPixelFormatType_OneComponent16" in mask_engine, "Instance mask 16-bit label-buffer support missing"
assert "func startTrackingSeedDiagnostic()" in view_model, "Tracking seed runtime entry missing"
assert "trackingSeedQuality: trackingSeedQualitySummary" in view_model, "Tracking seed summary missing from report"
assert "let trackingSeedQuality: TrackingSeedQualitySummary?" in report, "Backward-compatible optional tracking seed report field missing"
assert "tracking seed用boxを診断" in content_view, "Collapsed tracking seed control missing"
assert "tracking seed box診断" in report_view, "Tracking seed report UI missing"
assert "abs(actualOffset - offset) > 0.05" in view_model, "Boundary-clamped neighbor frames must not fake temporal stability"
assert "TrackingSeedBoxDiagnostics tests: PASS" in tracking_seed_test, "Tracking seed unit test marker missing"

coarse_start = view_model.index("private func runCoarseScan")
coarse_end = view_model.index("private func runDetailedScan", coarse_start)
coarse_block = view_model[coarse_start:coarse_end]
detail_start = view_model.index("private func runDetailedScan")
detail_end = view_model.index("private func buildSegments", detail_start)
detail_block = view_model[detail_start:detail_end]
assert "bestForegroundTrackingSeed" not in coarse_block, "Tracking seed diagnostics must not alter production coarse scan"
assert "bestForegroundTrackingSeed" not in detail_block, "Tracking seed diagnostics must not alter production detail scan"
assert "TrackingSeedBoxAnalyzer" not in coarse_block and "TrackingSeedBoxAnalyzer" not in detail_block, "Tracking seed analyzer must stay outside production scanning"

assert "abs(Double(vision.minY) - 0.30) < 0.0001" in tracking_seed_test, "Tracking seed coordinate test must use floating-point tolerance"


# v0.27: real Vision object-tracking A/B remains diagnostic-only.
object_tracking = Path("VideoTargetFinder/ObjectTrackingDiagnostics.swift").read_text(encoding="utf-8")
tracking_engine = Path("VideoTargetFinder/VisionObjectTrackingEngine.swift").read_text(encoding="utf-8")
object_tracking_test = Path("scripts/test_object_tracking_diagnostics.swift").read_text(encoding="utf-8")
assert "ObjectTrackingBenchmarkSummary" in object_tracking, "Object-tracking benchmark summary missing"
assert "paddedSeedRect" in object_tracking, "Tight/padded seed A/B helper missing"
assert "referenceAgreementRate" in object_tracking, "Independent foreground-reference agreement metric missing"
assert "VNSequenceRequestHandler" in tracking_engine, "Vision sequence request handler missing"
assert "VNTrackObjectRequest" in tracking_engine, "Real Vision object tracker missing"
assert "VNDetectedObjectObservation(boundingBox:" in tracking_engine, "Tracking seed observation missing"
assert "request.trackingLevel = .accurate" in tracking_engine, "Accurate tracking level missing"
assert "observation = next" in tracking_engine, "Tracked observation must seed the next frame"
assert "func startObjectTrackingDiagnostic()" in view_model, "Object-tracking runtime entry missing"
assert "VisionObjectTrackingEngine.track(" in view_model, "Runtime Vision tracking invocation missing"
assert "ObjectTrackingDiagnosticAnalyzer.paddedSeedRect" in view_model, "Tight/padded runtime A/B missing"
assert "objectTrackingBenchmark: objectTrackingBenchmarkSummary" in view_model, "Object-tracking report integration missing"
assert "let objectTrackingBenchmark: ObjectTrackingBenchmarkSummary?" in report, "Backward-compatible object-tracking report field missing"
assert "本物のobject trackingをA/B診断" in content_view, "Collapsed object-tracking diagnostic control missing"
assert "Vision object tracking A/B" in report_view, "Object-tracking report UI missing"
assert "ground truthではありません" in report_view, "Independent redetection limitation disclosure missing"
assert "ObjectTrackingDiagnostics tests: PASS" in object_tracking_test, "Object-tracking unit test marker missing"
assert "if viewModel.isRunningForegroundReserveDiagnostic ||" not in content_view, "Foreground progress UI must not be hijacked by another diagnostic state"

coarse_start = view_model.index("private func runCoarseScan")
coarse_end = view_model.index("private func runDetailedScan", coarse_start)
coarse_block = view_model[coarse_start:coarse_end]
detail_start = view_model.index("private func runDetailedScan")
detail_end = view_model.index("private func buildSegments", detail_start)
detail_block = view_model[detail_start:detail_end]
assert "VNTrackObjectRequest" not in coarse_block and "VisionObjectTrackingEngine" not in coarse_block, "Object tracking must not alter production coarse scan"
assert "VNTrackObjectRequest" not in detail_block and "VisionObjectTrackingEngine" not in detail_block, "Object tracking must not alter production detail scan"

assert "var lost = false" in tracking_engine, "Object tracker must preserve continuous-loss semantics"
assert "if lost {" in tracking_engine, "Frames after tracking loss must remain lost instead of being reacquired from a stale observation"
assert tracking_engine.count("lost = true") >= 2, "Both missing-result and request-error paths must terminate continuous tracking"


# v0.28 candidate hardening: async work must not overwrite or race user-visible state.
assert "var isDiagnosticWorkInProgress: Bool" in view_model, "Central diagnostic busy state missing"
assert "var isExclusiveWorkInProgress: Bool" in view_model, "Central exclusive-work state missing"
for signature in (
    "func loadVideo(from result: PHPickerResult)",
    "func setReferenceImages(_ images: [UIImage])",
    "func removeReferenceImage(at index: Int)",
    "func startHighAccuracyScan()",
    "func reviewSegment(id: UUID, as state: SegmentReviewState)",
    "func toggleSegmentSelection(id: UUID)",
    "func selectAllSegments()",
    "func deselectAllSegments()",
    "func applyFeedbackThreshold()",
    "func startFeedbackRescan()",
    "func prepareMaskingDiagnosticsIfNeeded() async",
    "func startExport()",
    "func restoreAndResumeInterruptedScan()",
    "func discardRecoverableScan()",
):
    start = view_model.index(signature)
    block = view_model[start:start + 700]
    assert "guard !isExclusiveWorkInProgress" in block, f"Exclusive-work guard missing: {signature}"

for availability in (
    "var canRunFeedbackRescan: Bool",
    "var canRunForegroundReserveRerankDiagnostic: Bool",
    "var canRunTrackingSeedDiagnostic: Bool",
    "var canRunObjectTrackingDiagnostic: Bool",
):
    start = view_model.index(availability)
    block = view_model[start:start + 500]
    assert "!isExclusiveWorkInProgress" in block, f"Exclusive-work availability gate missing: {availability}"

restore_start = view_model.index("func restoreAndResumeInterruptedScan()")
restore_block = view_model[restore_start:restore_start + 1400]
assert "isLoadingVideo = true" in restore_block, "Recovery preparation must lock competing work immediately"
assert "defer { self.isLoadingVideo = false }" in restore_block, "Recovery preparation lock must always release"

for publish_gate in (
    "try Task.checkCancellation()\n                self.foregroundReserveRerankSummary = summary",
    "try Task.checkCancellation()\n                self.trackingSeedQualitySummary = summary",
    "try Task.checkCancellation()\n                self.objectTrackingBenchmarkSummary = summary",
):
    assert publish_gate in view_model, f"Cancelled diagnostic can still publish stale results: {publish_gate}"

assert content.count(".disabled(viewModel.isExclusiveWorkInProgress)") >= 10, "Main UI mutations are not consistently locked"

runtime_test = Path("scripts/test_video_pipeline_runtime.swift").read_text(encoding="utf-8")
assert "control-original-generated" in runtime_test, "Robustness control fixture missing"
assert "let robustnessMatcher = try FeaturePrintMatcher(" in runtime_test, "Dedicated robustness matcher missing"
robust_start = runtime_test.index("let robustnessMatcher = try FeaturePrintMatcher(")
robust_end = runtime_test.index("let smallTarget", robust_start)
assert "negativeImages:" not in runtime_test[robust_start:robust_end], "Robustness matcher must not include hard negatives"
assert runtime_test.count("matcher: robustnessMatcher") == 4, "Control + three robustness cases must use the isolated matcher"

workflow = Path(".github/workflows/ios-build.yml").read_text(encoding="utf-8")
assert "video-target-finder-candidate" in workflow, "Candidate push trigger missing"
assert "workflow_dispatch" not in workflow, "Dead manual-dispatch path must not remain"
assert "contains(github.event.head_commit.message, '[full-ci]')" in workflow, "Candidate milestone CI marker missing"
assert Path("scripts/test_frame_region_coverage.swift").exists(), "Frame-region coverage test missing"
assert "test_frame_region_coverage.swift" in workflow, "Frame-region coverage test not wired into CI"


# Candidate review/export contract: newly detected segments must not be exported implicitly.
assert "var isSelectedForExport: Bool = false" in detected_segment, "New segments must start excluded from export until reviewed or explicitly selected"
assert "isSelectedForExport: Bool = false" in detected_segment, "DetectedSegment initializer must default export selection to false"
review_start = view_model.index("func reviewSegment(id: UUID, as state: SegmentReviewState)")
review_block = view_model[review_start:review_start + 1800]
assert "case .confirmed:\n            segments[index].isSelectedForExport = true" in review_block, "Confirmed candidates must become export-selected"
assert "case .rejected:\n            segments[index].isSelectedForExport = false" in review_block, "Rejected candidates must remain excluded from export"
threshold_start = view_model.index("func applyFeedbackThreshold()")
threshold_block = view_model[threshold_start:threshold_start + 1800]
assert "case .unreviewed:\n                segments[index].isSelectedForExport = segments[index].bestDistance <= threshold" in threshold_block, "Threshold action must remain an explicit way to select unreviewed candidates"

print("Repository regression verification: PASS")
