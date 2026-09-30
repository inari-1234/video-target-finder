import SwiftUI
import Photos
import UIKit

struct ContentView: View {
    @EnvironmentObject private var viewModel: VideoAnalysisViewModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("VideoTargetFinder.hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var showVideoPicker = false
    @State private var showReferencePicker = false
    @State private var previewSegment: DetectedSegment?
    @State private var showRecognitionReport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    videoCard
                    referenceCard
                    scanCard
                    if viewModel.isScanning || viewModel.hasRecoverableScan {
                        runtimeStabilityCard
                    }
                    reviewSettingsCard
                        .disabled(viewModel.isExclusiveWorkInProgress)
                    segmentsCard
                        .disabled(viewModel.isExclusiveWorkInProgress)
                    if viewModel.confirmedCount > 0 || viewModel.lastFeedbackRescanAddedCount > 0 {
                        feedbackLearningCard
                    }
                    exportCard
                    DisclosureGroup("詳細設定・診断") {
                        VStack(spacing: 16) {
                            settingsCard
                            recognitionReportCard
                            coarseResultsCard
                            statusCard
                            diagnosticsCard
                        }
                        .padding(.top, 10)
                    }
                }
                .padding()
            }
            .navigationTitle("推し動画メーカー")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOnboarding = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("使い方")
                }
            }
        }
        .sheet(isPresented: $showVideoPicker) {
            VideoPhotoPicker { result in
                viewModel.loadVideo(from: result)
            }
        }
        .sheet(isPresented: $showReferencePicker) {
            ReferenceImagesPicker(
                maxSelection: 5,
                onPick: { viewModel.setReferenceImages($0) },
                onError: { viewModel.setError($0) }
            )
        }
        .sheet(item: $previewSegment) { segment in
            if let asset = viewModel.videoAsset {
                let range = viewModel.adjustedRange(for: segment)
                SegmentPreviewSheet(
                    asset: asset,
                    startTime: range.start,
                    endTime: range.end,
                    title: "切り出し予定プレビュー"
                )
            } else {
                ContentUnavailableView("動画を開けません", systemImage: "exclamationmark.triangle")
            }
        }
        .sheet(isPresented: $showRecognitionReport) {
            RecognitionReportView(
                report: viewModel.recognitionQualityReportForDisplay(),
                combinedDiagnosticText: viewModel.combinedDiagnosticAndRecognitionReport()
            )
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            hasSeenOnboarding = true
        }) {
            OnboardingView(isPresented: $showOnboarding)
        }
        .task {
            if !hasSeenOnboarding {
                showOnboarding = true
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                viewModel.prepareForBackground()
            }
        }
        .alert("エラー", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "不明なエラー")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("長い動画から推しの登場場面を見つけて、短いまとめ動画を作ります。")
                .font(.headline)
            Text("基本操作は『動画を選ぶ → 推しの見本を選ぶ → 推しを探す → 候補を○/×確認 → 推し動画を作る』の5ステップです。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var videoCard: some View {
        GroupBox("1. 解析する動画") {
            VStack(alignment: .leading, spacing: 12) {
                if let metadata = viewModel.videoMetadata {
                    LabeledContent("長さ", value: metadata.durationText)
                    LabeledContent("解像度", value: metadata.resolutionText)
                    LabeledContent("フレームレート", value: metadata.frameRateText)
                } else {
                    Text("未選択")
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        if await viewModel.preparePhotoLibraryAccess() {
                            showVideoPicker = true
                        }
                    }
                } label: {
                    Label(
                        viewModel.videoAsset == nil ? "写真から動画を選択" : "動画を変更",
                        systemImage: "film"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isExclusiveWorkInProgress)

                if viewModel.isLoadingVideo {
                    ProgressView("動画を準備中…")
                }
            }
            .padding(.top, 6)
        }
    }

    private var referenceCard: some View {
        GroupBox("2. 探したい対象の見本画像（最大5枚）") {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.referenceImages.isEmpty {
                    ContentUnavailableView(
                        "見本画像なし",
                        systemImage: "photo.badge.plus",
                        description: Text("正面・横向きなど、対象の写り方が違う画像を複数入れると有利です。")
                    )
                    .frame(minHeight: 150)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(viewModel.referenceImages.enumerated()), id: \.offset) { index, image in
                                VStack(spacing: 6) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110, height: 110)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    HStack(spacing: 8) {
                                        Text("見本 \(index + 1)")
                                            .font(.caption)
                                        Button(role: .destructive) {
                                            viewModel.removeReferenceImage(at: index)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .disabled(viewModel.isExclusiveWorkInProgress)
                                    }
                                }
                            }
                        }
                    }
                }

                Button {
                    showReferencePicker = true
                } label: {
                    Label(
                        viewModel.referenceImages.isEmpty ? "見本画像を選択" : "見本画像を選び直す",
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isExclusiveWorkInProgress)

                Divider()

                TextField("対象名（任意・例：ダニエル）", text: $viewModel.targetLabel)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isExclusiveWorkInProgress)
                Text("入力すると精度レポート内で対象名として表示します。認識そのものは対象名ではなく画像特徴で行います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var settingsCard: some View {
        GroupBox("探索の詳細設定") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("感度", selection: $viewModel.sensitivity) {
                    ForEach(SearchSensitivity.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.isExclusiveWorkInProgress)

                Text(viewModel.sensitivity.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("粗探索間隔", selection: $viewModel.scanInterval) {
                    Text("0.5秒").tag(0.5)
                    Text("1秒").tag(1.0)
                    Text("2秒").tag(2.0)
                    Text("5秒").tag(5.0)
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.isExclusiveWorkInProgress)

                HStack {
                    Text("詳細探索")
                    Spacer()
                    Picker("詳細探索", selection: $viewModel.detailInterval) {
                        Text("0.10秒").tag(0.10)
                        Text("0.25秒").tag(0.25)
                        Text("0.50秒").tag(0.50)
                    }
                    .labelsHidden()
                    .disabled(viewModel.isExclusiveWorkInProgress)
                }

                Text("通常は初期値のままで構いません。候補付近だけを細かく再解析します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let threshold = viewModel.adaptiveThreshold {
                    LabeledContent(
                        "現在の自動候補しきい値",
                        value: String(format: "%.4f", threshold)
                    )
                    .font(.caption.monospacedDigit())
                }
            }
            .padding(.top, 6)
        }
    }

    private var scanCard: some View {
        GroupBox("3. 推しを探す") {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isScanning {
                    HStack {
                        Text(viewModel.scanPhase)
                            .font(.headline)
                        Spacer()
                        Text(viewModel.scanProgress.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    }
                    ProgressView(value: viewModel.scanProgress)
                    Button("解析をキャンセル", role: .destructive) {
                        viewModel.cancelScan()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Button {
                        viewModel.startHighAccuracyScan()
                    } label: {
                        Label("推しの登場場面を探す", systemImage: "sparkles.rectangle.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.videoAsset == nil || viewModel.referenceImages.isEmpty || viewModel.isExclusiveWorkInProgress)
                }

            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var runtimeStabilityCard: some View {
        GroupBox("解析の状態") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("端末温度", systemImage: "thermometer.medium")
                    Spacer()
                    Text(viewModel.thermalStateText)
                        .font(.subheadline.monospacedDigit())
                }

                if viewModel.isScanning {
                    if viewModel.isScanPaused {
                        Label(viewModel.pauseReason ?? "一時停止中", systemImage: "pause.circle.fill")
                            .font(.subheadline)
                        Button {
                            viewModel.resumeScan()
                        } label: {
                            Label("解析を再開", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            viewModel.pauseScan()
                        } label: {
                            Label("解析を一時停止", systemImage: "pause.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if viewModel.hasRecoverableScan && !viewModel.isScanning {
                    Divider()
                    Text("前回の粗探索チェックポイントがあります。アプリ終了前の途中位置から再開できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("前回の解析を再開") {
                            viewModel.restoreAndResumeInterruptedScan()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("破棄", role: .destructive) {
                            viewModel.discardRecoverableScan()
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(viewModel.isExclusiveWorkInProgress)
                }

                Text("高温時は自動的に処理速度を落とし、危険温度では停止します。バックグラウンドへ移ると安全のため一時停止します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var reviewSettingsCard: some View {
        GroupBox("4. 候補を確認") {
            if viewModel.segments.isEmpty {
                Text("解析後、候補を再生して推しなら「正解」、違えば「誤検出」を選びます。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("正解 \(viewModel.confirmedCount)", systemImage: "checkmark.circle.fill")
                        Spacer()
                        Label("誤検出 \(viewModel.rejectedCount)", systemImage: "xmark.circle.fill")
                        Spacer()
                        Text("未判定 \(viewModel.unreviewedCount)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    DisclosureGroup("切り出し・判定の詳細調整") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let threshold = viewModel.feedbackThreshold {
                                LabeledContent("推奨しきい値", value: String(format: "%.4f", threshold))
                                    .font(.caption.monospacedDigit())
                                if viewModel.feedbackHasOverlap {
                                    Text("正解と誤検出の画像特徴が重なっています。しきい値だけで自動判定せず、○/×確認を優先します。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button("未判定候補の採用可否にしきい値を適用") {
                                    viewModel.applyFeedbackThreshold()
                                }
                                .buttonStyle(.bordered)
                            }
                            Stepper(value: $viewModel.leadPadding, in: 0...5, step: 0.5) {
                                HStack {
                                    Text("候補の前に追加")
                                    Spacer()
                                    Text(String(format: "%.1f秒", viewModel.leadPadding)).monospacedDigit()
                                }
                            }
                            Stepper(value: $viewModel.trailPadding, in: 0...5, step: 0.5) {
                                HStack {
                                    Text("候補の後ろに追加")
                                    Spacer()
                                    Text(String(format: "%.1f秒", viewModel.trailPadding)).monospacedDigit()
                                }
                            }
                            HStack {
                                Button("すべて選択") { viewModel.selectAllSegments() }.buttonStyle(.bordered)
                                Button("すべて解除") { viewModel.deselectAllSegments() }.buttonStyle(.bordered)
                            }
                        }
                        .padding(.top, 6)
                    }

                    Text("切り出し予定: \(viewModel.selectedSegmentCount)区間 / 合計 約\(ScanCandidate.format(viewModel.selectedTotalDuration))")
                        .font(.subheadline.monospacedDigit())
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var segmentsCard: some View {
        GroupBox("候補一覧") {
            if viewModel.segments.isEmpty {
                Text("詳細探索が完了すると、連続した検出を1つの候補区間として表示します。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { index, segment in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(uiImage: segment.thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 112, height: 72)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("区間 \(index + 1)")
                                            .font(.headline)
                                        Image(systemName: segment.reviewState.symbolName)
                                            .accessibilityLabel(segment.reviewState.rawValue)
                                    }
                                    Text(segment.rangeText)
                                        .font(.body.monospacedDigit())
                                    Text(segment.durationText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            DisclosureGroup("候補の詳細") {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(viewModel.referenceLabel(for: segment.referenceIndex)) / \(segment.regionLabel)")
                                    Text("連続検出: \(segment.hitCount)ヒット / ヒット率 \(segment.trackingText)")
                                    Text("発見元: \(segment.discoverySource.rawValue)")
                                    Text("Feature distance: \(segment.distanceText)").monospacedDigit()
                                    let adjusted = viewModel.adjustedRange(for: segment)
                                    Text("切り出し予定: \(ScanCandidate.format(adjusted.start)) 〜 \(ScanCandidate.format(adjusted.end))").monospacedDigit()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            }

                            HStack(spacing: 8) {
                                Button {
                                    previewSegment = segment
                                } label: {
                                    Label("再生", systemImage: "play.rectangle")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    viewModel.reviewSegment(id: segment.id, as: .confirmed)
                                } label: {
                                    Label("正解", systemImage: "checkmark")
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) {
                                    viewModel.reviewSegment(id: segment.id, as: .rejected)
                                } label: {
                                    Label("誤検出", systemImage: "xmark")
                                }
                                .buttonStyle(.bordered)
                            }

                            Button {
                                viewModel.toggleSegmentSelection(id: segment.id)
                            } label: {
                                Label(
                                    segment.reviewState == .rejected
                                        ? "誤検出のため対象外"
                                        : (segment.isSelectedForExport ? "切り出し対象" : "対象外"),
                                    systemImage: segment.reviewState == .rejected
                                        ? "xmark.square"
                                        : (segment.isSelectedForExport ? "checkmark.square.fill" : "square")
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(segment.reviewState == .rejected)

                            if index < viewModel.segments.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var feedbackLearningCard: some View {
        GroupBox("見逃しをもう一度探す") {
            if viewModel.segments.isEmpty {
                Text("候補を検出して「正解」と判定すると、その場面を追加見本にして再探索できます。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("「正解」にした場面を手掛かりに、最初の検索で見逃した場面をもう一度探せます。")
                        .font(.subheadline)

                    DisclosureGroup("再探索の詳細") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("追加見本").font(.headline)
                                Spacer()
                                Text("\(viewModel.learnedReferences.count) / 8枚")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if !viewModel.learnedReferences.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(viewModel.learnedReferences.enumerated()), id: \.element.id) { index, item in
                                            VStack(spacing: 4) {
                                                Image(uiImage: item.image)
                                                    .resizable().scaledToFill()
                                                    .frame(width: 82, height: 82).clipped()
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                                Text("追加 \(index + 1)").font(.caption2)
                                            }
                                        }
                                    }
                                }
                            }
                            Picker("再探索間隔", selection: $viewModel.feedbackRescanInterval) {
                                Text("0.5秒").tag(0.5)
                                Text("1秒").tag(1.0)
                                Text("2秒").tag(2.0)
                            }
                            .pickerStyle(.segmented)
                            .disabled(viewModel.isExclusiveWorkInProgress)
                            Text("通常は1秒のままで構いません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }

                    if viewModel.isScanning && viewModel.scanPhase.contains("学習") {
                        HStack {
                            Text(viewModel.scanPhase)
                            Spacer()
                            Text(viewModel.scanProgress.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                        }
                        ProgressView(value: viewModel.scanProgress)
                    } else {
                        Button {
                            viewModel.startFeedbackRescan()
                        } label: {
                            Label("正解を使って見逃しを探す", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canRunFeedbackRescan)
                    }

                    if viewModel.lastFeedbackRescanAddedCount > 0 {
                        Label("前回の再探索で \(viewModel.lastFeedbackRescanAddedCount)区間を追加", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                    }

                    if let performance = viewModel.latestFeedbackRescanPerformanceRun {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("前回の再探索時間: \(String(format: "%.1f秒", performance.totalElapsedSeconds))")
                                .font(.caption.monospacedDigit())
                            ForEach(Array(performance.phases.enumerated()), id: \.offset) { _, phase in
                                Text("\(phase.phase.displayName): \(phase.elapsedText) / \(phase.sampleCount) samples / \(phase.rateText)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var recognitionReportCard: some View {
        GroupBox("認識精度レポート") {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.segments.isEmpty && viewModel.savedRecognitionReport == nil {
                    Text("候補を検出し、正解/誤検出を数件判定すると、参考画像・誤検出・見逃し・推奨設定の短評を生成できます。")
                        .foregroundStyle(.secondary)
                } else {
                    let report = viewModel.recognitionQualityReportForDisplay()
                    if viewModel.isShowingRecoveredRecognitionReport {
                        Label("前回の認識精度レポートを復旧しました", systemImage: "arrow.clockwise.icloud")
                            .font(.caption.bold())
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.summaryText)
                                .font(.subheadline)
                            Text("レポート信頼度: \(report.reportConfidence)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let rescanPrecision = report.rescanReviewedPrecision {
                                Text("学習再探索の判定済み正解率: \(rescanPrecision.formatted(.percent.precision(.fractionLength(0))))")
                                    .font(.caption.bold())
                            }
                        }
                        Spacer()
                    }

                    if let best = report.referenceEvaluations.first(where: { $0.grade == "最有効" }) {
                        Label("\(best.label): \(best.grade)", systemImage: "star.fill")
                            .font(.caption)
                    }

                    Text("推奨: 感度 \(report.recommendedSensitivity) / 粗探索 \(String(format: "%.2f秒", report.recommendedCoarseInterval)) / 詳細 \(String(format: "%.2f秒", report.recommendedDetailInterval))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        await viewModel.prepareMaskingDiagnosticsIfNeeded()
                        showRecognitionReport = true
                    }
                } label: {
                    Label(
                        viewModel.isPreparingMaskDiagnostics ? "背景影響を診断中…" : "精度レポートを開く",
                        systemImage: viewModel.isPreparingMaskDiagnostics
                            ? "hourglass"
                            : "chart.bar.doc.horizontal"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !viewModel.canGenerateRecognitionReport ||
                    viewModel.isExclusiveWorkInProgress
                )

                HStack {
                    Button {
                        Task {
                            await viewModel.prepareMaskingDiagnosticsIfNeeded()
                            UIPasteboard.general.string = viewModel.recognitionQualityReportText()
                        }
                    } label: {
                        Label("レポートをコピー", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            await viewModel.prepareMaskingDiagnosticsIfNeeded()
                            UIPasteboard.general.string = viewModel.combinedDiagnosticAndRecognitionReport()
                        }
                    } label: {
                        Label("診断もまとめてコピー", systemImage: "doc.on.doc.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(
                    !viewModel.canGenerateRecognitionReport ||
                    viewModel.isExclusiveWorkInProgress
                )

                DisclosureGroup("見逃し診断の詳細") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("初回analysis reserve内の候補時刻を固定したまま、foreground mask後のdistanceで仮想的に再順位します。通常の候補順位や認識結果は変更しません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if viewModel.isRunningForegroundReserveDiagnostic {
                            ProgressView(value: viewModel.foregroundReserveDiagnosticProgress)
                            Text(viewModel.foregroundReserveDiagnosticProgress.formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("前景mask再順位診断をキャンセル", role: .destructive) {
                                viewModel.cancelForegroundReserveRerankDiagnostic()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                viewModel.startForegroundReserveRerankDiagnostic()
                            } label: {
                                Label("前景maskで初回候補を再順位して診断", systemImage: "arrow.up.arrow.down.square")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!viewModel.canRunForegroundReserveRerankDiagnostic)
                        }

                        let currentReport = viewModel.recognitionQualityReportForDisplay()
                        if let rerank = currentReport.foregroundReserveRerank {
                            Text("詳細予算内の既知正解: 現在 \(rerank.baselineWithinBudgetCount) → mask再順位 \(rerank.shadowWithinBudgetCount) / \(rerank.knownPositiveInReserveCount)")
                                .font(.caption.monospacedDigit())
                            Text("予算内へ上昇 \(rerank.enteredBudgetCount) / 予算外へ下降 \(rerank.leftBudgetCount) / mask適用 \(rerank.maskAppliedCount)件")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if !viewModel.canRunForegroundReserveRerankDiagnostic {
                            Text("この診断には、初回analysis reserveが有効な解析と、学習再探索で追加された正解区間が必要です。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Text("Object trackingの前段として、正解候補のforeground instanceからtight bounding boxを作り、代表時刻±0.25秒でboxの安定性を測ります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if viewModel.isRunningTrackingSeedDiagnostic {
                            ProgressView(value: viewModel.trackingSeedDiagnosticProgress)
                            Text(viewModel.trackingSeedDiagnosticProgress.formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("tracking seed診断をキャンセル", role: .destructive) {
                                viewModel.cancelTrackingSeedDiagnostic()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                viewModel.startTrackingSeedDiagnostic()
                            } label: {
                                Label("tracking seed用boxを診断", systemImage: "viewfinder.rectangular")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!viewModel.canRunTrackingSeedDiagnostic)
                        }

                        let seedReport = viewModel.recognitionQualityReportForDisplay()
                        if let seed = seedReport.trackingSeedQuality {
                            Text("中心box取得 \(seed.centerSeedAvailableCount)/\(seed.candidateCount) / 3時刻取得 \(seed.threeFrameAvailableCount) / 安定 \(seed.stableSequenceCount)")
                                .font(.caption.monospacedDigit())
                            if let ratio = seed.meanSeedToSearchAreaRatio {
                                Text("平均box/検索窓面積比 \(String(format: "%.2f", ratio)) / edge接触 \(seed.centerEdgeTouchCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } else if !viewModel.canRunTrackingSeedDiagnostic {
                            Text("tracking seed診断には、初回探索で1件以上を正解判定してください。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Text("中央のforeground tight boxをseedに、Apple Visionのobject trackerを前後各1秒へ実際に走らせます。tight boxと10%余白boxを同じフレーム列でA/B比較し、同時刻のforeground再検出boxとの一致も測ります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if viewModel.isRunningObjectTrackingDiagnostic {
                            ProgressView(value: viewModel.objectTrackingDiagnosticProgress)
                            Text(viewModel.objectTrackingDiagnosticProgress.formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("object tracking診断をキャンセル", role: .destructive) {
                                viewModel.cancelObjectTrackingDiagnostic()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                viewModel.startObjectTrackingDiagnostic()
                            } label: {
                                Label("本物のobject trackingをA/B診断", systemImage: "scope")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!viewModel.canRunObjectTrackingDiagnostic)
                        }

                        let trackingReport = viewModel.recognitionQualityReportForDisplay()
                        if let tracking = trackingReport.objectTrackingBenchmark {
                            Text("tight: 継続 \(tracking.tight.continuationRate?.formatted(.percent.precision(.fractionLength(0))) ?? "n/a") / 参照一致 \(tracking.tight.referenceAgreementRate?.formatted(.percent.precision(.fractionLength(0))) ?? "n/a")")
                                .font(.caption.monospacedDigit())
                            Text("10%余白: 継続 \(tracking.padded.continuationRate?.formatted(.percent.precision(.fractionLength(0))) ?? "n/a") / 参照一致 \(tracking.padded.referenceAgreementRate?.formatted(.percent.precision(.fractionLength(0))) ?? "n/a")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if !viewModel.canRunObjectTrackingDiagnostic {
                            Text("object tracking診断には、初回探索で1件以上を正解判定してください。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                Text("正解率は判定済み候補内の実用指標です。厳密な動画全体precision/recallではありません。再探索で新たに正解になった区間を『見逃し疑い』として集計します。背景影響のmask A/Bは判定済み初回候補だけを、レポートを開く/コピーする時に未計算分だけ実行します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var exportCard: some View {
        GroupBox("5. 推し動画を作る") {
            if viewModel.segments.isEmpty {
                Text("候補区間を検出すると、ここから動画として保存できます。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("保存方法", selection: $viewModel.exportMode) {
                        ForEach(ExportMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.isExporting)

                    Text(viewModel.exportMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DisclosureGroup("書き出しの詳細設定") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("形式", selection: $viewModel.exportFormat) {
                                ForEach(ExportFormat.allCases) { format in
                                    Text(format.rawValue).tag(format)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(viewModel.isExporting)
                            Text(viewModel.exportFormat.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Stepper(value: $viewModel.exportMergeGap, in: 0...2, step: 0.25) {
                                HStack {
                                    Text("近接区間を統合")
                                    Spacer()
                                    Text(String(format: "%.2f秒以内", viewModel.exportMergeGap)).monospacedDigit()
                                }
                            }
                            .disabled(viewModel.isExporting)
                        }
                        .padding(.top, 4)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("選択 \(viewModel.selectedSegmentCount)候補 → 書き出し \(viewModel.mergedExportRangeCount)区間")
                            .font(.subheadline)
                        Text("内訳: 正解 \(viewModel.selectedConfirmedCount) / 未判定 \(viewModel.selectedUnreviewedCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if viewModel.selectedUnreviewedCount > 0 {
                            Label(
                                "未判定の候補が \(viewModel.selectedUnreviewedCount)件含まれています。必要ならStep 4で○/×確認してください。",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        Text("書き出し時間: 約\(ScanCandidate.format(viewModel.selectedTotalDuration))")
                            .font(.subheadline.monospacedDigit())
                        Text("重複・指定秒数以内の近接区間は、保存前に自動で1区間へまとめます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.isExporting {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(viewModel.exportPhase)
                                    .font(.headline)
                                Spacer()
                                Text(viewModel.exportProgress.formatted(.percent.precision(.fractionLength(0))))
                                    .monospacedDigit()
                            }
                            ProgressView(value: viewModel.exportProgress)
                            Button("書き出しをキャンセル", role: .destructive) {
                                viewModel.cancelExport()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        Button {
                            viewModel.startExport()
                        } label: {
                            Label(
                                viewModel.exportMode == .combined ? "推し動画を作る" : "個別クリップを作る",
                                systemImage: "wand.and.stars"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.mergedExportRangeCount == 0 || viewModel.isExclusiveWorkInProgress)
                    }

                    if let message = viewModel.lastExportMessage {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                    }

                    if !viewModel.pendingExportURLs.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Label("安全保存済みの動画", systemImage: "externaldrive.fill")
                                .font(.headline)

                            Text("完成動画は先にアプリ内へ安全保存します。『共有して写真へ保存』を開き、共有シートで『ビデオを保存』を選んでください。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(viewModel.pendingExportURLs, id: \.path) { url in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(url.lastPathComponent)
                                        .font(.caption.monospaced())
                                        .lineLimit(2)
                                    Text(viewModel.pendingExportSizeText(url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    HStack {
                                        ShareLink(item: url) {
                                            Label("共有して写真へ保存", systemImage: "square.and.arrow.up")
                                        }
                                        .buttonStyle(.borderedProminent)

                                        Button("削除", role: .destructive) {
                                            viewModel.deletePendingExport(url)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var coarseResultsCard: some View {
        GroupBox("粗探索の上位候補") {
            if viewModel.candidates.isEmpty {
                Text("まだ候補はありません。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(Array(viewModel.candidates.prefix(12).enumerated()), id: \.element.id) { index, candidate in
                        HStack(spacing: 12) {
                            Image(uiImage: candidate.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 62)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("候補 \(index + 1)  ·  \(candidate.timeText)")
                                    .font(.subheadline.monospacedDigit())
                                Text("\(viewModel.referenceLabel(for: candidate.referenceIndex)) / \(candidate.regionLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("distance: \(candidate.distanceText)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var statusCard: some View {
        GroupBox("状態") {
            Text(viewModel.statusMessage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
    }

    private var diagnosticsCard: some View {
        GroupBox("診断・設定") {
            VStack(alignment: .leading, spacing: 12) {
                Text("同じエラーが繰り返す場合は、診断情報をコピーして共有すると原因を追いやすくなります。動画そのものや見本画像の画像データは診断文へ含めません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    UIPasteboard.general.string = viewModel.diagnosticReport()
                } label: {
                    Label("診断情報をコピー", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    UIPasteboard.general.string = viewModel.combinedDiagnosticAndRecognitionReport()
                } label: {
                    Label("診断＋認識精度レポートをコピー", systemImage: "doc.on.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canGenerateRecognitionReport)

                HStack {
                    Button("設定を初期値へ戻す") {
                        viewModel.resetSavedSettings()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isExclusiveWorkInProgress)

                    Button("診断ログを消去", role: .destructive) {
                        viewModel.clearDiagnosticLog()
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    showOnboarding = true
                } label: {
                    Label("使い方をもう一度見る", systemImage: "questionmark.circle")
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
    }

}
