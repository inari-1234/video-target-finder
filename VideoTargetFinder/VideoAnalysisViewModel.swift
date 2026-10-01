@preconcurrency import AVFoundation
import Photos
import PhotosUI
import UIKit

private final class PlayerItemContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AVAsset, Error>?

    init(_ continuation: CheckedContinuation<AVAsset, Error>) {
        self.continuation = continuation
    }

    func succeed(_ asset: AVAsset) {
        take()?.resume(returning: asset)
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<AVAsset, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

@MainActor
final class VideoAnalysisViewModel: ObservableObject {
    @Published private(set) var videoAsset: AVAsset?
    @Published private(set) var videoMetadata: VideoMetadata?
    @Published private(set) var videoAssetIdentifier: String?
    @Published private(set) var referenceImages: [UIImage] = []
    @Published private(set) var isLoadingVideo = false
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var scanPhase = "待機"
    @Published private(set) var isScanPaused = false
    @Published private(set) var pauseReason: String?
    @Published private(set) var thermalStateText = "通常"
    @Published private(set) var hasRecoverableScan = ScanCheckpointStore.exists
    @Published private(set) var candidates: [ScanCandidate] = []
    @Published private(set) var segments: [DetectedSegment] = []
    @Published private(set) var adaptiveThreshold: Float?
    @Published private(set) var feedbackThreshold: Float?

    // Stage 6: feedback learning / re-scan state
    @Published private(set) var learnedReferences: [LearnedReference] = []
    @Published private(set) var lastFeedbackRescanAddedCount = 0

    // Stage 5: export state
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var exportPhase = "待機"
    @Published private(set) var lastExportMessage: String?
    @Published private(set) var savedRecognitionReport: RecognitionQualityReport?
    @Published private(set) var pendingExportURLs: [URL] = []
    @Published private(set) var isPreparingMaskDiagnostics = false
    @Published private(set) var isRunningForegroundReserveDiagnostic = false
    @Published private(set) var foregroundReserveDiagnosticProgress: Double = 0
    @Published private(set) var isRunningTrackingSeedDiagnostic = false
    @Published private(set) var trackingSeedDiagnosticProgress: Double = 0
    @Published private(set) var isRunningObjectTrackingDiagnostic = false
    @Published private(set) var objectTrackingDiagnosticProgress: Double = 0

    var isDiagnosticWorkInProgress: Bool {
        isPreparingMaskDiagnostics ||
        isRunningForegroundReserveDiagnostic ||
        isRunningTrackingSeedDiagnostic ||
        isRunningObjectTrackingDiagnostic
    }

    var isExclusiveWorkInProgress: Bool {
        isLoadingVideo || isScanning || isExporting || isDiagnosticWorkInProgress
    }

    @Published var scanInterval: Double = 2.0 { didSet { persistSettings() } }
    @Published var detailInterval: Double = 0.25 { didSet { persistSettings() } }
    @Published var feedbackRescanInterval: Double = 1.0 { didSet { persistSettings() } }
    @Published var sensitivity: SearchSensitivity = .balanced { didSet { persistSettings() } }
    @Published var leadPadding: Double = 1.0 { didSet { persistSettings() } }
    @Published var trailPadding: Double = 1.0 { didSet { persistSettings() } }
    @Published var exportMergeGap: Double = 0.25 { didSet { persistSettings() } }
    @Published var exportMode: ExportMode = .combined { didSet { persistSettings() } }
    @Published var exportFormat: ExportFormat = .movPreserve { didSet { persistSettings() } }
    @Published var statusMessage = "動画と見本画像を選択してください。"
    @Published var errorMessage: String?
    @Published var targetLabel: String = "" {
        didSet {
            UserDefaults.standard.set(targetLabel, forKey: "VideoTargetFinder.TargetLabel")
        }
    }

    private var scanTask: Task<Void, Never>?

    private struct CoarseFeatureCacheEntry: @unchecked Sendable {
        let actualTime: TimeInterval
        let features: PreparedFrameFeatures
    }

    private static let maxInitialCoarseFeatureCacheEntries = 900
    private static let maxInitialDetailFeatureCacheEntries = 500
    private static let cachedCandidatePlaceholder = UIImage(systemName: "photo") ?? UIImage()

    private struct FeedbackRescanRuntimeRun {
        let runNumber: Int
        let addedSegmentIDs: [UUID]
        let coarseCandidateLimit: Int
        let coarseCandidateCount: Int
        let positiveReferenceCount: Int
        let hardNegativeCount: Int
        let positiveAggregationMode: String
        let coarseFeatureCacheHits: Int
        let coarseFeatureFreshSamples: Int
        let detailFeatureCacheHits: Int
        let detailFeatureFreshSamples: Int
    }

    private var feedbackRescanRuns: [FeedbackRescanRuntimeRun] = []
    private var initialCoarseFeatureCache: [Int: CoarseFeatureCacheEntry] = [:]
    private var initialDetailFeatureCache: [Int: CoarseFeatureCacheEntry] = [:]
    private var initialDetailFeatureCacheSensitivity: SearchSensitivity?
    private var initialCoarseFeatureCacheSensitivity: SearchSensitivity?
    private var initialCoarseFeatureCacheInterval: TimeInterval?
    private var initialCoarseReserve: [CandidateBudgetPoint] = []
    private var initialDetailCandidateBudget = 0
    private var initialCoarseReserveLimit = 0
    private var initialDetailRadius: TimeInterval = 0
    private var initialCoarseReserveAnalysisAvailable = false
    private var checkpointReferencesWritten = false
    private var scanPerformanceRuns: [ScanPerformanceRunSummary] = []
    private var maskDiagnosticsBySegmentID: [UUID: CandidateMaskDiagnosticScores] = [:]
    private var maskDiagnosticTotalElapsedSeconds: Double = 0
    private var maskDiagnosticWasThermallyLimited = false
    private var foregroundReserveRerankSummary: ForegroundReserveRerankSummary?
    private var foregroundReserveDiagnosticTask: Task<Void, Never>?
    private var initialScanSensitivity: SearchSensitivity?
    private var trackingSeedQualitySummary: TrackingSeedQualitySummary?
    private var trackingSeedDiagnosticTask: Task<Void, Never>?
    private var objectTrackingBenchmarkSummary: ObjectTrackingBenchmarkSummary?
    private var objectTrackingDiagnosticTask: Task<Void, Never>?
    private var currentPhaseThermalPeak: ScanPerformanceThermalLevel = .nominal
    private var exportTask: Task<Void, Never>?
    private var isRestoringSettings = false

    init() {
        isRestoringSettings = true
        let saved = AppSettingsStore.load()
        scanInterval = saved.scanInterval
        detailInterval = saved.detailInterval
        feedbackRescanInterval = saved.feedbackRescanInterval
        sensitivity = SearchSensitivity(rawValue: saved.sensitivityRawValue) ?? .balanced
        leadPadding = saved.leadPadding
        trailPadding = saved.trailPadding
        exportMergeGap = saved.exportMergeGap
        exportMode = ExportMode(rawValue: saved.exportModeRawValue) ?? .combined
        exportFormat = ExportFormat(rawValue: saved.exportFormatRawValue) ?? .movPreserve
        targetLabel = UserDefaults.standard.string(forKey: "VideoTargetFinder.TargetLabel") ?? ""
        savedRecognitionReport = RecognitionReportSnapshotStore.load()
        pendingExportURLs = PendingExportStore.list()
        isRestoringSettings = false
        refreshThermalState()
        DiagnosticLogger.log("App launched; settings restored; savedReport=\(savedRecognitionReport != nil), pendingExports=\(pendingExportURLs.count)")
    }

    func preparePhotoLibraryAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return newStatus == .authorized || newStatus == .limited
        default:
            errorMessage = "写真へのアクセスが許可されていません。設定アプリから写真へのアクセスを許可してください。"
            return false
        }
    }

    func loadVideo(from result: PHPickerResult) {
        guard !isExclusiveWorkInProgress else { return }
        guard let identifier = result.assetIdentifier else {
            errorMessage = "この動画の写真ライブラリ識別子を取得できませんでした。"
            return
        }

        isLoadingVideo = true
        errorMessage = nil
        statusMessage = "動画情報を読み込んでいます…"
        DiagnosticLogger.log("Video load requested")

        Task {
            do {
                DiagnosticLogger.log("Video load step 1: requesting AVPlayerItem-backed asset")
                let asset = try await requestAVAsset(localIdentifier: identifier)
                DiagnosticLogger.log("Video load step 2: AVPlayerItem asset received; loading metadata")
                let metadata = try await makeMetadata(from: asset)
                DiagnosticLogger.log("Video load step 3: metadata loaded")
                // 新しい動画を安全に開けた時点でのみ、旧動画の復旧チェックポイントを無効化する。
                // 選択失敗やiCloud読込失敗では、前回の中断解析を失わない。
                ScanCheckpointStore.clear()
                hasRecoverableScan = false
                checkpointReferencesWritten = false
                videoAsset = asset
                videoMetadata = metadata
                videoAssetIdentifier = identifier
                resetResults()
                DiagnosticLogger.log("Video loaded: \(metadata.durationText), \(metadata.resolutionText), \(metadata.frameRateText)")
                statusMessage = referenceImages.isEmpty
                    ? "動画を読み込みました。次に見本画像を選択してください。"
                    : "準備完了。高精度解析を開始できます。"
            } catch {
                presentError(error, context: "動画の読み込み")
                statusMessage = "動画の読み込みに失敗しました。"
            }
            isLoadingVideo = false
        }
    }

    func setReferenceImages(_ images: [UIImage]) {
        guard !isExclusiveWorkInProgress else { return }
        ScanCheckpointStore.clear()
        hasRecoverableScan = false
        checkpointReferencesWritten = false
        referenceImages = Array(images.prefix(5))
        resetResults()
        errorMessage = nil
        statusMessage = videoAsset == nil
            ? "見本画像を設定しました。次に動画を選択してください。"
            : "準備完了。高精度解析を開始できます。"
    }

    func removeReferenceImage(at index: Int) {
        guard !isExclusiveWorkInProgress, referenceImages.indices.contains(index) else { return }
        // 見本構成が変わったため、旧見本を含む中断解析は復旧対象にできない。
        ScanCheckpointStore.clear()
        hasRecoverableScan = false
        checkpointReferencesWritten = false
        referenceImages.remove(at: index)
        resetResults()
        statusMessage = referenceImages.isEmpty
            ? "見本画像を1〜5枚選択してください。"
            : "見本画像を更新しました。"
    }

    func setError(_ error: Error) {
        presentError(error, context: nil)
    }

    func resetSavedSettings() {
        isRestoringSettings = true
        let defaults = AppSettings.defaults
        scanInterval = defaults.scanInterval
        detailInterval = defaults.detailInterval
        feedbackRescanInterval = defaults.feedbackRescanInterval
        sensitivity = .balanced
        leadPadding = defaults.leadPadding
        trailPadding = defaults.trailPadding
        exportMergeGap = defaults.exportMergeGap
        exportMode = .combined
        exportFormat = .movPreserve
        isRestoringSettings = false
        AppSettingsStore.save(currentSettings())
        DiagnosticLogger.log("Settings reset to defaults")
        statusMessage = "探索・書き出し設定を初期値へ戻しました。"
    }

    func diagnosticReport() -> String {
        var details: [String] = []
        if let metadata = videoMetadata {
            details.append("Video duration: \(metadata.durationText)")
            details.append("Video resolution: \(metadata.resolutionText)")
            details.append("Video fps: \(metadata.frameRateText)")
        } else {
            details.append("Video: not selected")
        }
        details.append("References: \(referenceImages.count)")
        details.append("Candidates: \(candidates.count)")
        details.append("Segments: \(segments.count)")
        details.append("Scanning: \(isScanning), paused: \(isScanPaused)")
        details.append("Exporting: \(isExporting)")
        details.append("Sensitivity: \(sensitivity.rawValue), coarse: \(scanInterval)s, detail: \(detailInterval)s")
        return DiagnosticLogger.report(extra: details.joined(separator: "\n"))
    }

    func clearDiagnosticLog() {
        DiagnosticLogger.clear()
        DiagnosticLogger.log("Diagnostic log cleared")
        statusMessage = "診断ログを消去しました。"
    }

    /// Stage 3: 粗探索 → 候補周辺の詳細探索 → 連続ヒットを区間化、まで自動で実行する。
    func startHighAccuracyScan() {
        guard !isExclusiveWorkInProgress else { return }
        guard let asset = videoAsset,
              let metadata = videoMetadata else {
            errorMessage = "解析する動画を選択してください。"
            return
        }

        let referenceCGImages = referenceImages.compactMap { $0.normalizedCGImage() }
        guard !referenceCGImages.isEmpty else {
            errorMessage = "見本画像を1枚以上選択してください。"
            return
        }

        let coarseInterval = max(0.5, scanInterval)
        let fineInterval = min(0.5, max(0.10, detailInterval))
        let selectedSensitivity = sensitivity
        let detailCandidateBudget = selectedSensitivity.coarseCandidateLimit
        let analysisReserveLimit = max(48, detailCandidateBudget * 4)

        resetResults()
        initialDetailCandidateBudget = detailCandidateBudget
        initialCoarseReserveLimit = analysisReserveLimit
        initialDetailRadius = selectedSensitivity.detailRadius
        initialScanSensitivity = selectedSensitivity
        initialCoarseReserveAnalysisAvailable = true
        isScanning = true
        isScanPaused = false
        pauseReason = nil
        checkpointReferencesWritten = false
        errorMessage = nil
        scanPhase = "粗探索"
        statusMessage = "動画全体を粗探索しています…"
        DiagnosticLogger.log("High accuracy scan started: sensitivity=\(selectedSensitivity.rawValue), coarse=\(coarseInterval), detail=\(fineInterval)")

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let matcher = try FeaturePrintMatcher(referenceImages: referenceCGImages)
                let generator = Self.makeImageGenerator(asset: asset, interval: coarseInterval)
                var performancePhases: [ScanPhasePerformanceSummary] = []
                let coarsePerformanceStart = self.beginPerformancePhase()
                let coarsePlannedSamples = self.coarseSampleCount(
                    duration: metadata.duration,
                    interval: coarseInterval,
                    startIndex: 0
                )

                let coarse = try await self.runCoarseScan(
                    generator: generator,
                    matcher: matcher,
                    duration: metadata.duration,
                    interval: coarseInterval,
                    sensitivity: selectedSensitivity,
                    startIndex: 0,
                    initialCandidates: [],
                    initialScores: [],
                    enablePersistentCheckpoint: true,
                    analysisReserveLimit: analysisReserveLimit,
                    captureFeatureCache: true
                )
                performancePhases.append(
                    self.finishPerformancePhase(
                        phase: .coarse,
                        startedAt: coarsePerformanceStart,
                        sampleCount: coarsePlannedSamples,
                        outputCount: coarse.candidates.count
                    )
                )
                self.recordPerformanceRun(kind: .initial, runNumber: nil, phases: performancePhases)
                DiagnosticLogger.log(
                    "Initial coarse Feature cache: stored=\(self.initialCoarseFeatureCache.count)/\(coarsePlannedSamples), cap=\(Self.maxInitialCoarseFeatureCacheEntries)"
                )

                try Task.checkCancellation()
                self.initialCoarseReserve = coarse.analysisReserve
                self.candidates = coarse.candidates
                self.adaptiveThreshold = coarse.threshold
                let initialCandidatePoints = coarse.candidates.map {
                    CandidateBudgetPoint(time: $0.time, distance: $0.distance)
                }
                let reservePrefixVerified = CandidateBudgetAnalyzer.prefixMatches(
                    normalCandidates: initialCandidatePoints,
                    rankedReserve: coarse.analysisReserve
                )
                self.initialCoarseReserveAnalysisAvailable = reservePrefixVerified
                DiagnosticLogger.log(
                    "Initial coarse reserve: retained=\(coarse.analysisReserve.count)/\(analysisReserveLimit), detailBudget=\(detailCandidateBudget), prefixVerified=\(reservePrefixVerified)"
                )

                guard !coarse.candidates.isEmpty else {
                    ScanCheckpointStore.clear()
                    self.hasRecoverableScan = false
                    self.scanProgress = 1
                    self.scanPhase = "完了"
                    self.statusMessage = "粗探索が完了しましたが、候補を取得できませんでした。"
                    self.finishScan()
                    return
                }

                self.scanPhase = "詳細探索"
                self.scanProgress = 0
                self.statusMessage = "候補地点の前後を細かく再解析しています…"

                let detailGenerator = Self.makeImageGenerator(asset: asset, interval: fineInterval)
                let windows = self.makeDetailWindows(
                    from: coarse.candidates,
                    duration: metadata.duration,
                    radius: selectedSensitivity.detailRadius
                )

                let detailThreshold = ScanPipelineCore.detailThreshold(coarseThreshold: coarse.threshold)
                let detailPlannedSamples = self.detailSampleCount(windows: windows, interval: fineInterval)
                let detailPerformanceStart = self.beginPerformancePhase()
                let detail = try await self.runDetailedScan(
                    generator: detailGenerator,
                    matcher: matcher,
                    windows: windows,
                    interval: fineInterval,
                    sensitivity: selectedSensitivity,
                    threshold: detailThreshold,
                    captureFeatureCache: true
                )
                performancePhases.append(
                    self.finishPerformancePhase(
                        phase: .detail,
                        startedAt: detailPerformanceStart,
                        sampleCount: detailPlannedSamples,
                        outputCount: detail.hits.count
                    )
                )
                self.recordPerformanceRun(kind: .initial, runNumber: nil, phases: performancePhases)
                DiagnosticLogger.log(
                    "Initial detail Feature cache: stored=\(self.initialDetailFeatureCache.count)/\(detailPlannedSamples), cap=\(Self.maxInitialDetailFeatureCacheEntries)"
                )

                try Task.checkCancellation()
                self.segments = self.buildSegments(
                    from: detail.hits,
                    duration: metadata.duration,
                    detailInterval: fineInterval
                )
                ScanCheckpointStore.clear()
                self.hasRecoverableScan = false
                self.scanProgress = 1
                self.scanPhase = "完了"
                self.statusMessage = self.segments.isEmpty
                    ? "解析完了。明確な連続区間は作れませんでした。粗探索候補を確認してください。"
                    : "解析完了。\(self.segments.count)個の候補区間を作成しました。"
            } catch is CancellationError {
                self.scanPhase = "キャンセル"
                self.statusMessage = "解析をキャンセルしました。"
            } catch {
                self.presentError(error, context: "AI解析")
                self.scanPhase = "エラー"
                self.statusMessage = "解析に失敗しました。"
            }

            self.finishScan()
        }
    }

    func cancelScan() {
        DiagnosticLogger.log("Scan cancellation requested")
        scanTask?.cancel()
    }

    // MARK: - Stage 4 review / selection

    var confirmedCount: Int {
        segments.filter { $0.reviewState == .confirmed }.count
    }

    var rejectedCount: Int {
        segments.filter { $0.reviewState == .rejected }.count
    }

    var unreviewedCount: Int {
        segments.filter { $0.reviewState == .unreviewed }.count
    }

    var selectedSegmentCount: Int {
        segments.filter(\.isSelectedForExport).count
    }

    var selectedConfirmedCount: Int {
        segments.filter { $0.isSelectedForExport && $0.reviewState == .confirmed }.count
    }

    var selectedUnreviewedCount: Int {
        segments.filter { $0.isSelectedForExport && $0.reviewState == .unreviewed }.count
    }

    var feedbackHasOverlap: Bool {
        let positives = segments.filter { $0.reviewState == .confirmed }.map(\.bestDistance)
        let negatives = segments.filter { $0.reviewState == .rejected }.map(\.bestDistance)
        guard let positiveMax = positives.max(), let negativeMin = negatives.min() else { return false }
        return positiveMax >= negativeMin
    }

    var selectedTotalDuration: TimeInterval {
        mergedSelectedExportRanges.reduce(0) { $0 + $1.duration }
    }

    var mergedSelectedExportRanges: [ExportTimeRange] {
        makeMergedExportRanges()
    }

    var mergedExportRangeCount: Int {
        mergedSelectedExportRanges.count
    }

    func reviewSegment(id: UUID, as state: SegmentReviewState) {
        guard !isExclusiveWorkInProgress else { return }
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let changedDiscoverySource = segments[index].discoverySource
        segments[index].reviewState = state
        if changedDiscoverySource == .feedbackRescan {
            foregroundReserveRerankSummary = nil
        }
        if changedDiscoverySource == .initial {
            trackingSeedQualitySummary = nil
            objectTrackingBenchmarkSummary = nil
        }

        switch state {
        case .confirmed:
            segments[index].isSelectedForExport = true
        case .rejected:
            segments[index].isSelectedForExport = false
        case .unreviewed:
            break
        }

        refreshLearnedReferencesFromConfirmedSegments()
        feedbackThreshold = calculateSuggestedFeedbackThreshold()
        statusMessage = "判定を更新しました。正解 \(confirmedCount) / 誤検出 \(rejectedCount) / 未判定 \(unreviewedCount) / 学習見本 \(learnedReferences.count)"
        persistRecognitionReportSnapshot(reason: "review-updated")
    }

    func toggleSegmentSelection(id: UUID) {
        guard !isExclusiveWorkInProgress else { return }
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        guard segments[index].reviewState != .rejected else {
            segments[index].isSelectedForExport = false
            statusMessage = "誤検出と判定した候補は切り出し対象にできません。正解に変更してから選択してください。"
            return
        }
        segments[index].isSelectedForExport.toggle()
    }

    func selectAllSegments() {
        guard !isExclusiveWorkInProgress else { return }
        for index in segments.indices {
            if segments[index].reviewState != .rejected {
                segments[index].isSelectedForExport = true
            }
        }
    }

    func deselectAllSegments() {
        guard !isExclusiveWorkInProgress else { return }
        for index in segments.indices {
            segments[index].isSelectedForExport = false
        }
    }

    func applyFeedbackThreshold() {
        guard !isExclusiveWorkInProgress else { return }
        guard let threshold = feedbackThreshold else {
            statusMessage = "正解または誤検出を1件以上判定すると、推奨しきい値を計算できます。"
            return
        }

        for index in segments.indices {
            switch segments[index].reviewState {
            case .confirmed:
                segments[index].isSelectedForExport = true
            case .rejected:
                segments[index].isSelectedForExport = false
            case .unreviewed:
                segments[index].isSelectedForExport = segments[index].bestDistance <= threshold
            }
        }

        statusMessage = "フィードバックしきい値を未判定候補へ適用しました。\(selectedSegmentCount)区間を切り出し対象にしています。"
    }

    // MARK: - Stage 6 feedback learning / re-scan

    var canRunFeedbackRescan: Bool {
        !learnedReferences.isEmpty && videoAsset != nil && !isExclusiveWorkInProgress
    }

    var latestFeedbackRescanPerformanceRun: ScanPerformanceRunSummary? {
        scanPerformanceRuns.last { $0.kind == .feedbackRescan }
    }

    /// 正解判定された候補の「最も一致した局所領域」を追加見本にし、動画全体を再走査する。
    /// 既存の正解/誤検出判定は保持し、新しく見つかった非重複区間だけを候補へ追加する。
    func startFeedbackRescan() {
        guard !isExclusiveWorkInProgress else { return }
        guard let asset = videoAsset, let metadata = videoMetadata else {
            errorMessage = "再探索する動画を選択してください。"
            return
        }

        refreshLearnedReferencesFromConfirmedSegments()
        guard !learnedReferences.isEmpty else {
            errorMessage = "候補を1件以上「正解」と判定してから再探索してください。"
            return
        }

        let originalCGImages = referenceImages.compactMap { $0.normalizedCGImage() }
        let learnedCGImages = learnedReferences.compactMap { $0.image.normalizedCGImage() }
        let combinedReferences = Array((originalCGImages + learnedCGImages).prefix(13))
        guard !combinedReferences.isEmpty else {
            errorMessage = "再探索に使える見本画像を生成できませんでした。"
            return
        }

        // Stage 14: 誤検出の中でも、正解見本に近くて紛らわしかったものを hard negative として優先する。
        let negativeReferences = segments
            .filter { $0.reviewState == .rejected }
            .sorted { $0.bestDistance < $1.bestDistance }
            .prefix(8)
            .compactMap { $0.matchThumbnail.normalizedCGImage() }

        let preservedSegments = segments
        let rescanRunNumber = feedbackRescanRuns.count + 1
        let coarseInterval = max(0.5, min(5.0, feedbackRescanInterval))
        let fineInterval = min(0.5, max(0.10, detailInterval))
        let selectedSensitivity = sensitivity

        isScanning = true
        isScanPaused = false
        pauseReason = nil
        lastFeedbackRescanAddedCount = 0
        scanProgress = 0
        scanPhase = "学習再探索"
        errorMessage = nil
        statusMessage = "正解から作った追加見本 \(learnedReferences.count)枚で動画全体を再探索しています…"

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let matcher = try FeaturePrintMatcher(
                    referenceImages: combinedReferences,
                    negativeImages: negativeReferences,
                    positiveAggregationMode: .top2Mean
                )
                let generator = Self.makeImageGenerator(asset: asset, interval: coarseInterval)
                let expandedCandidateLimit = max(48, selectedSensitivity.coarseCandidateLimit * 4)
                var performancePhases: [ScanPhasePerformanceSummary] = []
                let coarsePerformanceStart = self.beginPerformancePhase()
                let coarsePlannedSamples = self.coarseSampleCount(
                    duration: metadata.duration,
                    interval: coarseInterval,
                    startIndex: 0
                )
                DiagnosticLogger.log("Feedback rescan matcher: positives=\(combinedReferences.count), negatives=\(negativeReferences.count), candidateLimit=\(expandedCandidateLimit), positiveAggregation=top2Mean")

                let coarse = try await self.runCoarseScan(
                    generator: generator,
                    matcher: matcher,
                    duration: metadata.duration,
                    interval: coarseInterval,
                    sensitivity: selectedSensitivity,
                    startIndex: 0,
                    initialCandidates: [],
                    initialScores: [],
                    enablePersistentCheckpoint: false,
                    candidateLimit: expandedCandidateLimit,
                    reuseFeatureCache: true
                )
                let hydratedCoarseCandidates = coarse.featureCacheHits > 0
                    ? await self.hydrateCandidateThumbnails(
                        coarse.candidates,
                        asset: asset,
                        interval: coarseInterval
                    )
                    : coarse.candidates
                performancePhases.append(
                    self.finishPerformancePhase(
                        phase: .coarse,
                        startedAt: coarsePerformanceStart,
                        sampleCount: coarsePlannedSamples,
                        outputCount: hydratedCoarseCandidates.count
                    )
                )
                DiagnosticLogger.log(
                    "Feedback coarse Feature cache: hits=\(coarse.featureCacheHits), fresh=\(coarse.freshFeatureSamples), cachedInitial=\(self.initialCoarseFeatureCache.count)"
                )
                self.recordPerformanceRun(
                    kind: .feedbackRescan,
                    runNumber: rescanRunNumber,
                    phases: performancePhases
                )

                try Task.checkCancellation()
                self.candidates = hydratedCoarseCandidates
                self.adaptiveThreshold = coarse.threshold

                guard !hydratedCoarseCandidates.isEmpty else {
                    self.lastFeedbackRescanAddedCount = 0
                    self.feedbackRescanRuns.append(
                        FeedbackRescanRuntimeRun(
                            runNumber: rescanRunNumber,
                            addedSegmentIDs: [],
                            coarseCandidateLimit: expandedCandidateLimit,
                            coarseCandidateCount: 0,
                            positiveReferenceCount: combinedReferences.count,
                            hardNegativeCount: negativeReferences.count,
                            positiveAggregationMode: "top2Mean",
                            coarseFeatureCacheHits: coarse.featureCacheHits,
                            coarseFeatureFreshSamples: coarse.freshFeatureSamples,
                            detailFeatureCacheHits: 0,
                            detailFeatureFreshSamples: 0
                        )
                    )
                    self.scanProgress = 1
                    self.scanPhase = "完了"
                    self.statusMessage = "学習再探索は完了しましたが、新しい候補は見つかりませんでした。"
                    self.persistRecognitionReportSnapshot(reason: "feedback-rescan-completed-empty")
                    self.finishScan()
                    return
                }

                self.scanPhase = "学習詳細探索"
                self.scanProgress = 0
                self.statusMessage = "学習再探索の候補地点を細かく再確認しています…"

                let detailGenerator = Self.makeImageGenerator(asset: asset, interval: fineInterval)
                let windows = self.makeDetailWindows(
                    from: hydratedCoarseCandidates,
                    duration: metadata.duration,
                    radius: selectedSensitivity.detailRadius
                )
                // 再探索は見逃し低減を優先して初回より少し広めに詳細確認する。
                let detailThreshold = coarse.threshold + max(0.025, coarse.threshold * 0.12)
                let detailPlannedSamples = self.detailSampleCount(windows: windows, interval: fineInterval)
                let detailPerformanceStart = self.beginPerformancePhase()
                let detail = try await self.runDetailedScan(
                    generator: detailGenerator,
                    matcher: matcher,
                    windows: windows,
                    interval: fineInterval,
                    sensitivity: selectedSensitivity,
                    threshold: detailThreshold,
                    reuseFeatureCache: true
                )
                performancePhases.append(
                    self.finishPerformancePhase(
                        phase: .detail,
                        startedAt: detailPerformanceStart,
                        sampleCount: detailPlannedSamples,
                        outputCount: detail.hits.count
                    )
                )
                DiagnosticLogger.log(
                    "Feedback detail Feature cache: hits=\(detail.featureCacheHits), fresh=\(detail.freshFeatureSamples), cachedInitial=\(self.initialDetailFeatureCache.count)"
                )
                self.recordPerformanceRun(
                    kind: .feedbackRescan,
                    runNumber: rescanRunNumber,
                    phases: performancePhases
                )

                try Task.checkCancellation()
                let rescannedSegments = self.buildSegments(
                    from: detail.hits,
                    duration: metadata.duration,
                    detailInterval: fineInterval
                )
                let merged = self.mergeFeedbackRescanSegments(
                    existing: preservedSegments,
                    newSegments: rescannedSegments
                )
                let preservedIDs = Set(preservedSegments.map(\.id))
                let addedIDs = merged
                    .filter { !preservedIDs.contains($0.id) }
                    .map(\.id)
                self.lastFeedbackRescanAddedCount = addedIDs.count
                self.feedbackRescanRuns.append(
                    FeedbackRescanRuntimeRun(
                        runNumber: rescanRunNumber,
                        addedSegmentIDs: addedIDs,
                        coarseCandidateLimit: expandedCandidateLimit,
                        coarseCandidateCount: hydratedCoarseCandidates.count,
                        positiveReferenceCount: combinedReferences.count,
                        hardNegativeCount: negativeReferences.count,
                        positiveAggregationMode: "top2Mean",
                        coarseFeatureCacheHits: coarse.featureCacheHits,
                        coarseFeatureFreshSamples: coarse.freshFeatureSamples,
                        detailFeatureCacheHits: detail.featureCacheHits,
                        detailFeatureFreshSamples: detail.freshFeatureSamples
                    )
                )
                self.segments = merged
                self.refreshLearnedReferencesFromConfirmedSegments()
                self.feedbackThreshold = self.calculateSuggestedFeedbackThreshold()
                self.scanProgress = 1
                self.scanPhase = "完了"
                self.statusMessage = self.lastFeedbackRescanAddedCount == 0
                    ? "学習再探索が完了しました。新しい非重複候補はありませんでした。"
                    : "学習再探索で新しい候補を \(self.lastFeedbackRescanAddedCount)区間追加しました。"
                self.persistRecognitionReportSnapshot(reason: "feedback-rescan-completed")
            } catch is CancellationError {
                self.segments = preservedSegments
                self.scanPhase = "キャンセル"
                self.statusMessage = "学習再探索をキャンセルしました。既存の判定は保持しています。"
            } catch {
                self.segments = preservedSegments
                self.errorMessage = error.localizedDescription
                self.scanPhase = "エラー"
                self.statusMessage = "学習再探索に失敗しました。既存の判定は保持しています。"
            }

            self.finishScan()
        }
    }

    func referenceLabel(for index: Int) -> String {
        if index < referenceImages.count {
            return "見本 \(index + 1)"
        }
        return "学習見本 \(index - referenceImages.count + 1)"
    }

    // MARK: - Stage 15 recognition quality report

    var canGenerateRecognitionReport: Bool {
        !referenceImages.isEmpty || !segments.isEmpty || savedRecognitionReport != nil
    }

    var isShowingRecoveredRecognitionReport: Bool {
        referenceImages.isEmpty && segments.isEmpty && savedRecognitionReport != nil
    }

    var canRunForegroundReserveRerankDiagnostic: Bool {
        !isExclusiveWorkInProgress &&
        videoAsset != nil &&
        initialCoarseReserveAnalysisAvailable &&
        !initialCoarseReserve.isEmpty &&
        initialDetailCandidateBudget > 0 &&
        initialDetailRadius > 0 &&
        initialScanSensitivity != nil &&
        rescanConfirmedCountForReport > 0
    }

    func startForegroundReserveRerankDiagnostic() {
        guard canRunForegroundReserveRerankDiagnostic,
              let asset = videoAsset,
              let initialSensitivity = initialScanSensitivity else {
            statusMessage = "前景mask再順位診断には、初回analysis reserveと再探索で確認した正解区間が必要です。"
            return
        }

        let references = referenceImages.compactMap { $0.normalizedCGImage() }
        guard !references.isEmpty else { return }

        let reserve = initialCoarseReserve
        let budget = initialDetailCandidateBudget
        let radius = initialDetailRadius
        let knownSegments = segments
            .filter { $0.discoverySource == .feedbackRescan && $0.reviewState == .confirmed }
            .map { CandidateBudgetKnownSegment(startTime: $0.startTime, endTime: $0.endTime) }

        isRunningForegroundReserveDiagnostic = true
        foregroundReserveDiagnosticProgress = 0
        statusMessage = "analysis reserveを前景maskで再順位しています…"

        foregroundReserveDiagnosticTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var points: [ForegroundReserveRerankPoint] = []
            points.reserveCapacity(reserve.count)
            var frameFailures = 0
            var thermallyLimited = false

            do {
                let matcher = try FeaturePrintMatcher(referenceImages: references)
                let generator = Self.makeExactDiagnosticImageGenerator(asset: asset)

                for (index, stored) in reserve.enumerated() {
                    try Task.checkCancellation()

                    let thermal = self.currentThermalLevel()
                    self.refreshThermalState()
                    switch thermal {
                    case .critical:
                        thermallyLimited = true
                    case .serious:
                        try await Task.sleep(for: .milliseconds(220))
                    case .fair:
                        try await Task.sleep(for: .milliseconds(60))
                    case .nominal, .unknown:
                        break
                    }
                    if thermallyLimited { break }

                    do {
                        let requestedTime = CMTime(seconds: stored.time, preferredTimescale: 600)
                        let frame = try await generator.image(at: requestedTime)
                        let match = try await self.matchFrame(
                            frame.image,
                            matcher: matcher,
                            sensitivity: initialSensitivity
                        )
                        let crop = FrameRegionSampler.croppedImage(
                            from: frame.image,
                            normalizedRect: match.regionNormalizedRect
                        ) ?? frame.image

                        let baselineConsistent = ForegroundReserveRerankAnalyzer.baselineIsConsistent(
                            stored: stored.distance,
                            rerun: match.distance
                        )
                        let box = SendableCGImageBox(crop)
                        let masked = await Task.detached(priority: .utility) {
                            autoreleasepool {
                                VisionMaskDiagnosticEngine.foregroundUnionDistance(
                                    image: box.image,
                                    matcher: matcher
                                )
                            }
                        }.value

                        points.append(
                            ForegroundReserveRerankPoint(
                                time: stored.time,
                                baselineDistance: stored.distance,
                                rerunBaselineDistance: match.distance,
                                maskedDistance: masked.distance,
                                baselineConsistent: baselineConsistent,
                                maskRequestFailed: masked.requestFailed,
                                wasProcessed: true
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        frameFailures += 1
                        points.append(
                            ForegroundReserveRerankPoint(
                                time: stored.time,
                                baselineDistance: stored.distance,
                                rerunBaselineDistance: nil,
                                maskedDistance: nil,
                                baselineConsistent: false,
                                maskRequestFailed: false,
                                wasProcessed: true
                            )
                        )
                    }

                    self.foregroundReserveDiagnosticProgress = Double(index + 1) / Double(max(1, reserve.count))
                    if index % 4 == 0 { await Task.yield() }
                }

                if points.count < reserve.count {
                    for stored in reserve.dropFirst(points.count) {
                        points.append(
                            ForegroundReserveRerankPoint(
                                time: stored.time,
                                baselineDistance: stored.distance,
                                rerunBaselineDistance: nil,
                                maskedDistance: nil,
                                baselineConsistent: false,
                                maskRequestFailed: false,
                                wasProcessed: false
                            )
                        )
                    }
                }

                let summary = ForegroundReserveRerankAnalyzer.summarize(
                    points: points,
                    detailBudget: budget,
                    detailRadius: radius,
                    knownSegments: knownSegments,
                    elapsedSeconds: max(0, Date().timeIntervalSince(startedAt)),
                    wasThermallyLimited: thermallyLimited,
                    frameEvaluationFailureCount: frameFailures
                )
                try Task.checkCancellation()
                self.foregroundReserveRerankSummary = summary
                self.foregroundReserveDiagnosticProgress = thermallyLimited ? Double(points.filter(\.wasProcessed).count) / Double(max(1, reserve.count)) : 1
                self.statusMessage = thermallyLimited
                    ? "端末温度が高いため、前景mask再順位診断を途中で止めました。未処理候補は元distanceへfallbackしています。"
                    : "前景mask再順位診断が完了しました。精度レポートで初回候補順位への影響を確認できます。"
                self.persistRecognitionReportSnapshot(reason: "foreground-reserve-rerank-updated")
            } catch is CancellationError {
                self.statusMessage = "前景mask再順位診断をキャンセルしました。"
            } catch {
                self.presentError(error, context: "前景mask再順位診断")
                self.statusMessage = "前景mask再順位診断に失敗しました。"
            }

            self.isRunningForegroundReserveDiagnostic = false
            self.foregroundReserveDiagnosticTask = nil
        }
    }

    func cancelForegroundReserveRerankDiagnostic() {
        foregroundReserveDiagnosticTask?.cancel()
    }

    var canRunTrackingSeedDiagnostic: Bool {
        !isExclusiveWorkInProgress &&
        videoAsset != nil &&
        initialScanSensitivity != nil &&
        segments.contains {
            $0.discoverySource == .initial && $0.reviewState == .confirmed
        }
    }

    func startTrackingSeedDiagnostic() {
        guard canRunTrackingSeedDiagnostic,
              let asset = videoAsset,
              let initialSensitivity = initialScanSensitivity else {
            statusMessage = "tracking seed診断には、初回探索で正解判定した候補が必要です。"
            return
        }

        let references = referenceImages.compactMap { $0.normalizedCGImage() }
        guard !references.isEmpty else { return }

        let targets = Array(
            segments
                .filter { $0.discoverySource == .initial && $0.reviewState == .confirmed }
                .sorted { $0.bestDistance < $1.bestDistance }
                .prefix(8)
        )
        guard !targets.isEmpty else { return }

        isRunningTrackingSeedDiagnostic = true
        trackingSeedDiagnosticProgress = 0
        statusMessage = "foreground maskからtracking seed boxを診断しています…"

        trackingSeedDiagnosticTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var diagnostics: [TrackingSeedCandidateDiagnostic] = []
            var unsupportedFormats = 0
            var frameFailures = 0
            var thermallyLimited = false
            let offsets: [Double] = [-0.25, 0, 0.25]

            do {
                let matcher = try FeaturePrintMatcher(referenceImages: references)
                let generator = Self.makeExactDiagnosticImageGenerator(asset: asset)

                for (targetIndex, segment) in targets.enumerated() {
                    try Task.checkCancellation()
                    guard let searchRegion = FrameRegionSampler.regions(for: initialSensitivity)
                        .first(where: { $0.label == segment.regionLabel }) else {
                        frameFailures += offsets.count
                        continue
                    }

                    var samples: [TrackingSeedFrameSample] = []
                    for offset in offsets {
                        try Task.checkCancellation()
                        let thermal = self.currentThermalLevel()
                        self.refreshThermalState()
                        switch thermal {
                        case .critical:
                            thermallyLimited = true
                        case .serious:
                            try await Task.sleep(for: .milliseconds(220))
                        case .fair:
                            try await Task.sleep(for: .milliseconds(60))
                        case .nominal, .unknown:
                            break
                        }
                        if thermallyLimited { break }

                        let requestedSeconds = max(
                            0,
                            min((self.videoMetadata?.duration ?? segment.bestTime) - 0.001,
                                segment.bestTime + offset)
                        )
                        let actualOffset = requestedSeconds - segment.bestTime
                        if abs(actualOffset - offset) > 0.05 {
                            samples.append(
                                TrackingSeedFrameSample(
                                    offsetSeconds: actualOffset,
                                    visionRect: nil,
                                    featureDistance: nil,
                                    touchesSearchCropEdge: false
                                )
                            )
                            continue
                        }

                        do {
                            let frame = try await generator.image(
                                at: CMTime(seconds: requestedSeconds, preferredTimescale: 600)
                            )
                            guard let crop = FrameRegionSampler.croppedImage(
                                from: frame.image,
                                normalizedRect: searchRegion.normalizedRect
                            ) else {
                                frameFailures += 1
                                samples.append(
                                    TrackingSeedFrameSample(
                                        offsetSeconds: actualOffset,
                                        visionRect: nil,
                                        featureDistance: nil,
                                        touchesSearchCropEdge: false
                                    )
                                )
                                continue
                            }

                            let box = SendableCGImageBox(crop)
                            let result = await Task.detached(priority: .utility) {
                                autoreleasepool {
                                    VisionMaskDiagnosticEngine.bestForegroundTrackingSeed(
                                        image: box.image,
                                        matcher: matcher
                                    )
                                }
                            }.value

                            if result.unsupportedMaskFormat { unsupportedFormats += 1 }
                            if result.requestFailed { frameFailures += 1 }

                            let visionRect = result.localTopLeftRect.flatMap {
                                TrackingSeedBoxAnalyzer.mapLocalTopLeftRectToVision(
                                    $0,
                                    searchRegionTopLeft: searchRegion.normalizedRect
                                )
                            }
                            samples.append(
                                TrackingSeedFrameSample(
                                    offsetSeconds: actualOffset,
                                    visionRect: visionRect,
                                    featureDistance: result.featureDistance,
                                    touchesSearchCropEdge: result.touchesMaskEdge
                                )
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            frameFailures += 1
                            samples.append(
                                TrackingSeedFrameSample(
                                    offsetSeconds: actualOffset,
                                    visionRect: nil,
                                    featureDistance: nil,
                                    touchesSearchCropEdge: false
                                )
                            )
                        }
                    }

                    diagnostics.append(
                        TrackingSeedCandidateDiagnostic(
                            segmentID: segment.id,
                            searchRegionArea: Double(
                                searchRegion.normalizedRect.width * searchRegion.normalizedRect.height
                            ),
                            samples: samples
                        )
                    )
                    self.trackingSeedDiagnosticProgress =
                        Double(targetIndex + 1) / Double(max(1, targets.count))
                    if thermallyLimited { break }
                    await Task.yield()
                }

                let summary = TrackingSeedBoxAnalyzer.summarize(
                    candidates: diagnostics,
                    elapsedSeconds: max(0, Date().timeIntervalSince(startedAt)),
                    wasThermallyLimited: thermallyLimited,
                    unsupportedMaskFormatCount: unsupportedFormats,
                    frameFailureCount: frameFailures
                )
                try Task.checkCancellation()
                self.trackingSeedQualitySummary = summary
                self.trackingSeedDiagnosticProgress = thermallyLimited
                    ? Double(diagnostics.count) / Double(max(1, targets.count))
                    : 1
                self.statusMessage = thermallyLimited
                    ? "端末温度が高いためtracking seed診断を途中で止めました。"
                    : "tracking seed診断が完了しました。精度レポートでboxのtightnessと前後安定性を確認できます。"
                self.persistRecognitionReportSnapshot(reason: "tracking-seed-diagnostic-updated")
            } catch is CancellationError {
                self.statusMessage = "tracking seed診断をキャンセルしました。"
            } catch {
                self.presentError(error, context: "tracking seed診断")
                self.statusMessage = "tracking seed診断に失敗しました。"
            }

            self.isRunningTrackingSeedDiagnostic = false
            self.trackingSeedDiagnosticTask = nil
        }
    }

    func cancelTrackingSeedDiagnostic() {
        trackingSeedDiagnosticTask?.cancel()
    }

    var canRunObjectTrackingDiagnostic: Bool {
        !isExclusiveWorkInProgress &&
        videoAsset != nil &&
        initialScanSensitivity != nil &&
        segments.contains {
            $0.discoverySource == .initial && $0.reviewState == .confirmed
        }
    }

    func startObjectTrackingDiagnostic() {
        guard canRunObjectTrackingDiagnostic,
              let asset = videoAsset,
              let metadata = videoMetadata,
              let initialSensitivity = initialScanSensitivity else {
            statusMessage = "object tracking診断には、初回探索で正解判定した候補が必要です。"
            return
        }

        let references = referenceImages.compactMap { $0.normalizedCGImage() }
        guard !references.isEmpty else { return }

        let targets = Array(
            segments
                .filter { $0.discoverySource == .initial && $0.reviewState == .confirmed }
                .sorted { $0.bestDistance < $1.bestDistance }
                .prefix(4)
        )
        guard !targets.isEmpty else { return }

        isRunningObjectTrackingDiagnostic = true
        objectTrackingDiagnosticProgress = 0
        statusMessage = "Vision object trackingを前後フレームでA/B診断しています…"

        objectTrackingDiagnosticTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            let step = 0.125
            let stepsPerDirection = 8
            var diagnostics: [ObjectTrackingCandidateDiagnostic] = []
            var seedFailures = 0
            var referenceFailures = 0
            var frameFailures = 0
            var thermallyLimited = false

            do {
                let matcher = try FeaturePrintMatcher(referenceImages: references)
                let generator = Self.makeExactDiagnosticImageGenerator(asset: asset)

                for (targetIndex, segment) in targets.enumerated() {
                    try Task.checkCancellation()
                    guard let searchRegion = FrameRegionSampler.regions(for: initialSensitivity)
                        .first(where: { $0.label == segment.regionLabel }) else {
                        seedFailures += 1
                        continue
                    }

                    let centerFrame: CGImage
                    do {
                        let center = try await generator.image(
                            at: CMTime(seconds: segment.bestTime, preferredTimescale: 600)
                        )
                        centerFrame = center.image
                    } catch {
                        seedFailures += 1
                        frameFailures += 1
                        continue
                    }

                    guard let centerCrop = FrameRegionSampler.croppedImage(
                        from: centerFrame,
                        normalizedRect: searchRegion.normalizedRect
                    ) else {
                        seedFailures += 1
                        continue
                    }

                    let centerBox = SendableCGImageBox(centerCrop)
                    let seedResult = await Task.detached(priority: .utility) {
                        autoreleasepool {
                            VisionMaskDiagnosticEngine.bestForegroundTrackingSeed(
                                image: centerBox.image,
                                matcher: matcher
                            )
                        }
                    }.value
                    guard let localSeed = seedResult.localTopLeftRect,
                          let tightSeed = TrackingSeedBoxAnalyzer.mapLocalTopLeftRectToVision(
                            localSeed,
                            searchRegionTopLeft: searchRegion.normalizedRect
                          ) else {
                        seedFailures += 1
                        continue
                    }

                    let paddedSeed = ObjectTrackingDiagnosticAnalyzer.paddedSeedRect(tightSeed)
                    var directionInputs: [ObjectTrackingDirection: [CGImage]] = [:]
                    var directionReferences: [ObjectTrackingDirection: [(Double, CGRect?)]] = [:]

                    for direction in [ObjectTrackingDirection.forward, .backward] {
                        var images: [CGImage] = []
                        var refs: [(Double, CGRect?)] = []

                        for stepIndex in 1...stepsPerDirection {
                            try Task.checkCancellation()
                            let thermal = self.currentThermalLevel()
                            self.refreshThermalState()
                            switch thermal {
                            case .critical:
                                thermallyLimited = true
                            case .serious:
                                try await Task.sleep(for: .milliseconds(220))
                            case .fair:
                                try await Task.sleep(for: .milliseconds(60))
                            case .nominal, .unknown:
                                break
                            }
                            if thermallyLimited { break }

                            let signedOffset = Double(stepIndex) * step * (direction == .forward ? 1 : -1)
                            let requested = segment.bestTime + signedOffset
                            guard requested >= 0, requested < metadata.duration else { continue }

                            do {
                                let frame = try await generator.image(
                                    at: CMTime(seconds: requested, preferredTimescale: 600)
                                )
                                images.append(frame.image)

                                var referenceRect: CGRect?
                                if let crop = FrameRegionSampler.croppedImage(
                                    from: frame.image,
                                    normalizedRect: searchRegion.normalizedRect
                                ) {
                                    let cropBox = SendableCGImageBox(crop)
                                    let redetected = await Task.detached(priority: .utility) {
                                        autoreleasepool {
                                            VisionMaskDiagnosticEngine.bestForegroundTrackingSeed(
                                                image: cropBox.image,
                                                matcher: matcher
                                            )
                                        }
                                    }.value
                                    referenceRect = redetected.localTopLeftRect.flatMap {
                                        TrackingSeedBoxAnalyzer.mapLocalTopLeftRectToVision(
                                            $0,
                                            searchRegionTopLeft: searchRegion.normalizedRect
                                        )
                                    }
                                    if referenceRect == nil { referenceFailures += 1 }
                                } else {
                                    referenceFailures += 1
                                }
                                refs.append((signedOffset, referenceRect))
                            } catch {
                                frameFailures += 1
                            }
                        }

                        directionInputs[direction] = images
                        directionReferences[direction] = refs
                        if thermallyLimited { break }
                    }

                    var variants: [ObjectTrackingVariantDiagnostic] = []
                    for (variant, seed) in [
                        (ObjectTrackingSeedVariant.tight, tightSeed),
                        (ObjectTrackingSeedVariant.padded, paddedSeed)
                    ] {
                        var variantSamples: [ObjectTrackingFrameDiagnostic] = []

                        for direction in [ObjectTrackingDirection.forward, .backward] {
                            let images = directionInputs[direction] ?? []
                            let refs = directionReferences[direction] ?? []
                            guard !images.isEmpty else { continue }

                            let imageSequence = SendableCGImageSequence(images: images)
                            let tracked = await Task.detached(priority: .utility) {
                                VisionObjectTrackingEngine.track(
                                    images: imageSequence.images,
                                    seedRect: seed
                                )
                            }.value

                            for index in 0..<max(tracked.count, refs.count) {
                                let output = index < tracked.count ? tracked[index] : nil
                                let reference = index < refs.count ? refs[index] : nil
                                variantSamples.append(
                                    ObjectTrackingFrameDiagnostic(
                                        direction: direction,
                                        offsetSeconds: reference?.0 ?? 0,
                                        trackedRect: output?.boundingBox,
                                        confidence: output?.confidence,
                                        referenceRect: reference?.1
                                    )
                                )
                            }
                        }

                        variants.append(
                            ObjectTrackingVariantDiagnostic(
                                variant: variant,
                                samples: variantSamples
                            )
                        )
                    }

                    diagnostics.append(
                        ObjectTrackingCandidateDiagnostic(
                            segmentID: segment.id,
                            seedRect: tightSeed,
                            variants: variants
                        )
                    )
                    self.objectTrackingDiagnosticProgress =
                        Double(targetIndex + 1) / Double(max(1, targets.count))
                    if thermallyLimited { break }
                    await Task.yield()
                }

                let summary = ObjectTrackingDiagnosticAnalyzer.benchmark(
                    candidates: diagnostics,
                    elapsedSeconds: max(0, Date().timeIntervalSince(startedAt)),
                    wasThermallyLimited: thermallyLimited,
                    seedFailureCount: seedFailures,
                    referenceDetectionFailureCount: referenceFailures,
                    frameLoadFailureCount: frameFailures
                )
                try Task.checkCancellation()
                self.objectTrackingBenchmarkSummary = summary
                self.objectTrackingDiagnosticProgress = thermallyLimited
                    ? Double(diagnostics.count) / Double(max(1, targets.count))
                    : 1
                self.statusMessage = thermallyLimited
                    ? "端末温度が高いためobject tracking診断を途中で止めました。"
                    : "object tracking A/B診断が完了しました。精度レポートでtight/padded seedを比較できます。"
                self.persistRecognitionReportSnapshot(reason: "object-tracking-diagnostic-updated")
            } catch is CancellationError {
                self.statusMessage = "object tracking診断をキャンセルしました。"
            } catch {
                self.presentError(error, context: "object tracking診断")
                self.statusMessage = "object tracking診断に失敗しました。"
            }

            self.isRunningObjectTrackingDiagnostic = false
            self.objectTrackingDiagnosticTask = nil
        }
    }

    func cancelObjectTrackingDiagnostic() {
        objectTrackingDiagnosticTask?.cancel()
    }

    /// 判定済みの初回候補だけを、現在のFeature Print baselineとVision maskでpaired A/Bする。
    /// 通常探索には接続せず、認識レポートを開く/コピーする時に未計算分だけ実行する。
    func prepareMaskingDiagnosticsIfNeeded() async {
        guard !isExclusiveWorkInProgress else { return }

        let pending = segments.filter {
            $0.discoverySource == .initial &&
            $0.reviewState != .unreviewed &&
            maskDiagnosticsBySegmentID[$0.id] == nil
        }
        guard !pending.isEmpty else { return }

        let references = referenceImages.compactMap { $0.normalizedCGImage() }
        guard !references.isEmpty else { return }

        isPreparingMaskDiagnostics = true
        maskDiagnosticWasThermallyLimited = false
        let startedAt = Date()
        defer {
            isPreparingMaskDiagnostics = false
        }

        do {
            let matcher = try FeaturePrintMatcher(referenceImages: references)
            for segment in pending {
                try Task.checkCancellation()

                let thermal = currentThermalLevel()
                refreshThermalState()
                switch thermal {
                case .critical:
                    maskDiagnosticWasThermallyLimited = true
                    statusMessage = "端末温度が高いため背景影響診断を途中で止めました。温度が下がれば次回レポート表示時に続きから診断します。"
                    break
                case .serious:
                    try await Task.sleep(for: .milliseconds(220))
                case .fair:
                    try await Task.sleep(for: .milliseconds(60))
                case .nominal, .unknown:
                    break
                }
                if maskDiagnosticWasThermallyLimited { break }

                guard let image = segment.matchThumbnail.normalizedCGImage() else { continue }
                let box = SendableCGImageBox(image)
                let scores = try await Task.detached(priority: .utility) {
                    try autoreleasepool {
                        try VisionMaskDiagnosticEngine.evaluate(
                            image: box.image,
                            matcher: matcher
                        )
                    }
                }.value
                maskDiagnosticsBySegmentID[segment.id] = scores
                await Task.yield()
            }
            maskDiagnosticTotalElapsedSeconds += max(0, Date().timeIntervalSince(startedAt))
            persistRecognitionReportSnapshot(reason: "mask-diagnostic-updated")
        } catch is CancellationError {
            maskDiagnosticTotalElapsedSeconds += max(0, Date().timeIntervalSince(startedAt))
            DiagnosticLogger.log("Mask diagnostic cancelled")
        } catch {
            maskDiagnosticTotalElapsedSeconds += max(0, Date().timeIntervalSince(startedAt))
            DiagnosticLogger.log("Mask diagnostic failed: \(error.localizedDescription)")
        }
    }

    func recognitionQualityReportForDisplay() -> RecognitionQualityReport {
        if !referenceImages.isEmpty || !segments.isEmpty {
            return makeRecognitionQualityReport()
        }
        if let savedRecognitionReport {
            return savedRecognitionReport
        }
        return makeRecognitionQualityReport()
    }

    private func persistRecognitionReportSnapshot(reason: String) {
        guard !referenceImages.isEmpty || !segments.isEmpty else { return }
        let report = makeRecognitionQualityReport()
        do {
            try RecognitionReportSnapshotStore.save(report)
            savedRecognitionReport = report
            DiagnosticLogger.log("Recognition report snapshot saved: reason=\(reason), confirmed=\(report.confirmedCount), rejected=\(report.rejectedCount)")
        } catch {
            DiagnosticLogger.log("Recognition report snapshot save failed: \(error.localizedDescription)")
        }
    }

    func makeRecognitionQualityReport() -> RecognitionQualityReport {
        let positives = segments.filter { $0.reviewState == .confirmed }.map(\.bestDistance)
        let negatives = segments.filter { $0.reviewState == .rejected }.map(\.bestDistance)
        let reviewed = confirmedCount + rejectedCount
        let reviewedPrecision = reviewed > 0 ? Double(confirmedCount) / Double(reviewed) : nil
        let rescanSegments = segments.filter { $0.discoverySource == .feedbackRescan }
        let runSummaries: [FeedbackRescanRunSummary] = feedbackRescanRuns.map { run in
            let ids = Set(run.addedSegmentIDs)
            let confirmed = segments.filter {
                ids.contains($0.id) && $0.reviewState == .confirmed
            }.count
            let rejected = segments.filter {
                ids.contains($0.id) && $0.reviewState == .rejected
            }.count
            return FeedbackRescanRunSummary(
                runNumber: run.runNumber,
                addedCount: run.addedSegmentIDs.count,
                confirmedCount: confirmed,
                rejectedCount: rejected,
                coarseCandidateLimit: run.coarseCandidateLimit,
                coarseCandidateCount: run.coarseCandidateCount,
                positiveReferenceCount: run.positiveReferenceCount,
                hardNegativeCount: run.hardNegativeCount,
                positiveAggregationMode: run.positiveAggregationMode,
                coarseFeatureCacheHits: run.coarseFeatureCacheHits,
                coarseFeatureFreshSamples: run.coarseFeatureFreshSamples,
                detailFeatureCacheHits: run.detailFeatureCacheHits,
                detailFeatureFreshSamples: run.detailFeatureFreshSamples
            )
        }
        let rescanAddedTotal = runSummaries.isEmpty
            ? rescanSegments.count
            : runSummaries.reduce(0) { $0 + $1.addedCount }
        let rescanConfirmed = runSummaries.isEmpty
            ? rescanSegments.filter { $0.reviewState == .confirmed }.count
            : runSummaries.reduce(0) { $0 + $1.confirmedCount }
        let rescanRejected = runSummaries.isEmpty
            ? rescanSegments.filter { $0.reviewState == .rejected }.count
            : runSummaries.reduce(0) { $0 + ($1.rejectedCount ?? 0) }
        let candidateBudgetAnalysis = makeCandidateBudgetAnalysis()
        let aggregationBenchmark = makeReferenceAggregationBenchmark()
        let feedbackAggregationBenchmark = makeFeedbackRescanAggregationBenchmark()
        let maskingBenchmark = makeMaskingBenchmark()
        let averageTracking = segments.isEmpty ? nil : segments.map(\.trackingScore).reduce(0, +) / Double(segments.count)

        let confirmedByOriginalReference = (0..<referenceImages.count).map { index in
            segments.filter { $0.referenceIndex == index && $0.reviewState == .confirmed }.count
        }
        let strongestReferenceIndex = confirmedByOriginalReference.enumerated().max(by: { $0.element < $1.element })?.offset

        let evaluations: [ReferenceQualityEvaluation] = referenceImages.indices.map { index in
            let matched = segments.filter { $0.referenceIndex == index }
            let confirmed = matched.filter { $0.reviewState == .confirmed }
            let rejected = matched.filter { $0.reviewState == .rejected }
            let unreviewed = matched.filter { $0.reviewState == .unreviewed }
            let contribution = confirmedCount > 0
                ? Double(confirmed.count) / Double(confirmedCount)
                : (segments.isEmpty ? 0 : Double(matched.count) / Double(segments.count))
            let positiveMean = averageFloat(confirmed.map(\.bestDistance))
            let negativeMean = averageFloat(rejected.map(\.bestDistance))

            let grade: String
            let comment: String
            if matched.isEmpty {
                grade = "寄与未確認"
                comment = "この見本を最良一致として使った候補がまだありません。向きや大きさが他の見本と重複している可能性があります。"
            } else if rejected.count >= max(2, confirmed.count) {
                grade = "誤検出注意"
                comment = "誤検出への寄与が高めです。背景・周辺キャラクター・衣装など対象以外の特徴を拾っている可能性があります。中央寄りの画像や顔が大きい画像を優先してください。"
            } else if index == strongestReferenceIndex && confirmed.count >= 2 {
                grade = "最有効"
                comment = "正解候補への寄与が最も高い見本です。次回も基準画像として残すことを推奨します。"
            } else if confirmed.count >= 2 && confirmed.count > rejected.count {
                grade = "有効"
                comment = "正解候補への寄与が安定しています。向きや距離の違う見本と組み合わせると見逃し低減に役立ちます。"
            } else if confirmed.count == 1 && rejected.isEmpty {
                grade = "補助的に有効"
                comment = "正解への寄与は確認できましたが、判定数がまだ少ないため追加データで評価すると確実です。"
            } else {
                grade = "情報不足"
                comment = "現時点では正解・誤検出の差が十分に判断できません。候補を数件判定してから再度レポートを確認してください。"
            }

            return ReferenceQualityEvaluation(
                id: index,
                label: "見本 \(index + 1)",
                matchCount: matched.count,
                confirmedCount: confirmed.count,
                rejectedCount: rejected.count,
                unreviewedCount: unreviewed.count,
                contributionPercent: contribution,
                positiveMeanDistance: positiveMean,
                negativeMeanDistance: negativeMean,
                grade: grade,
                comment: comment
            )
        }

        var falsePositiveComments: [String] = []
        if rejectedCount >= 3 {
            falsePositiveComments.append("誤検出が \(rejectedCount)件あります。誤検出をhard negativeとして学習してから再探索する価値があります。")
        }
        if feedbackHasOverlap {
            falsePositiveComments.append("正解と誤検出のdistance分布が重なっています。しきい値調整だけでは分離しにくく、負例学習が重要です。")
        }
        if let positiveMean = averageFloat(positives), let negativeMean = averageFloat(negatives), negativeMean - positiveMean < 0.03 {
            falsePositiveComments.append("正解と誤検出の平均distance差が小さく、見た目の近い別対象を拾いやすい状態です。")
        }
        let rejectedWholeFrameCount = segments.filter { $0.reviewState == .rejected && $0.regionLabel == "画面全体" }.count
        if rejectedWholeFrameCount >= 2 {
            falsePositiveComments.append("画面全体一致の誤検出が複数あります。背景や舞台全体の特徴が影響している可能性があります。")
        }

        var missedComments: [String] = []
        if rescanConfirmed > 0 {
            missedComments.append("学習再探索で新たに正解 \(rescanConfirmed)件が見つかりました。初回探索には見逃しがあったと判断できます。")
        }
        if let budget = candidateBudgetAnalysis {
            if budget.outsideInitialBudgetCount > 0 {
                missedComments.append("再探索で正解になったうち \(budget.outsideInitialBudgetCount)件は、初回粗探索では分析用候補に入っていましたが、詳細探索へ送る上位 \(budget.initialDetailBudget)件の外でした。候補予算が見逃し要因の可能性があります。")
            }
            if budget.withinInitialBudgetCount > 0 {
                missedComments.append("再探索で正解になったうち \(budget.withinInitialBudgetCount)件は、初回の詳細探索範囲にも含まれていました。詳細しきい値・連続検出・区間化側の見逃しが疑われます。")
            }
            if budget.notInInitialReserveCount > 0 {
                missedComments.append("再探索で正解になったうち \(budget.notInInitialReserveCount)件は、初回の分析用粗候補にも入りませんでした。粗探索間隔または画像特徴表現の影響が疑われます。")
            }
        } else if lastFeedbackRescanAddedCount >= 3 {
            missedComments.append("直近の再探索で候補が \(lastFeedbackRescanAddedCount)件増えています。旧解析のため、候補予算と画像特徴のどちらが主因かは分離できません。")
        }
        if let averageTracking, averageTracking < 0.55, confirmedCount > 0 {
            missedComments.append("候補の連続検出率が低めです。一瞬の登場や向き変化で検出が途切れている可能性があります。")
        }

        let shouldShortenCoarse: Bool = {
            guard rescanConfirmed > 0 || lastFeedbackRescanAddedCount >= 3 else { return false }
            guard let budget = candidateBudgetAnalysis else { return true }
            return budget.notInInitialReserveCount > 0
        }()
        let shouldTightenDetail = (averageTracking ?? 1) < 0.55
            || (candidateBudgetAnalysis?.withinInitialBudgetCount ?? 0) > 0
        let recommendedCoarse: Double = shouldShortenCoarse ? min(scanInterval, 1.0) : scanInterval
        let recommendedDetail: Double = shouldTightenDetail ? 0.10 : min(detailInterval, 0.25)
        let recommendedSensitivity: SearchSensitivity = {
            if reviewed >= 4, let reviewedPrecision, reviewedPrecision < 0.45 {
                return .balanced
            }
            if rescanConfirmed >= 2, let reviewedPrecision, reviewedPrecision >= 0.60 {
                return .thorough
            }
            return sensitivity
        }()

        var guidance: [String] = []
        if reviewed < 3 {
            guidance.append("正解/誤検出をあと \(3 - reviewed)件以上判定すると、レポートの信頼度が上がります。")
        }
        if let strongestReferenceIndex, confirmedByOriginalReference[strongestReferenceIndex] > 0 {
            guidance.append("見本 \(strongestReferenceIndex + 1) は正解への寄与が最も高いため、次回も残すことを推奨します。")
        }
        if evaluations.contains(where: { $0.grade == "誤検出注意" }) {
            guidance.append("『誤検出注意』の見本は、対象を大きく中央に写した別画像へ置き換えると改善しやすいです。")
        }
        if rejectedCount >= 3 {
            guidance.append("誤検出を3件以上残した状態で学習再探索を実行し、hard negativeを活用してください。")
        }
        if rescanConfirmed > 0 {
            guidance.append("再探索で見つかった正解画像は、向き・距離の異なる追加見本として有効です。")
        }
        if let budget = candidateBudgetAnalysis, budget.outsideInitialBudgetCount > 0 {
            guidance.append("初回候補予算外の正解が確認できたため、次のA/B検証では画像特徴を変えずに詳細探索へ送る候補数だけを増やし、見逃し改善と処理時間を比較してください。")
        }
        if let budget = candidateBudgetAnalysis, budget.notInInitialReserveCount > 0 {
            guidance.append("初回粗探索にも入らなかった正解があるため、候補数だけでなく粗探索間隔と次世代embedding方式の比較対象にしてください。")
        }
        if let budget = candidateBudgetAnalysis, budget.withinInitialBudgetCount > 0 {
            guidance.append("初回の詳細探索範囲内でも見逃した正解があるため、詳細しきい値・連続ヒット条件・区間化を候補数とは分けて検証してください。")
        }
        if recommendedCoarse < scanInterval {
            guidance.append("次回は粗探索を \(String(format: "%.2f", recommendedCoarse))秒に短縮し、短時間登場の見逃しを減らすことを推奨します。")
        }
        if recommendedDetail < detailInterval {
            guidance.append("詳細探索を \(String(format: "%.2f", recommendedDetail))秒にすると、一瞬の登場や連続検出切れを拾いやすくなります。")
        }
        if guidance.isEmpty {
            guidance.append("現設定は大きく崩れていません。正解/誤検出の判定を増やし、レポートを再生成して微調整してください。")
        }

        let confidence: String = {
            if reviewed >= 8 { return "高" }
            if reviewed >= 3 { return "中" }
            return "低（判定数不足）"
        }()

        let videoComment = makeVideoSelectionComment(reviewedPrecision: reviewedPrecision)

        return RecognitionQualityReport(
            generatedAt: Date(),
            evaluationSchemaVersion: 13,
            recognitionEngine: "Apple Vision Feature Print",
            targetLabel: targetLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            videoDurationText: videoMetadata?.durationText ?? "未選択",
            videoResolutionText: videoMetadata?.resolutionText ?? "未選択",
            videoFrameRateText: videoMetadata?.frameRateText ?? "未選択",
            videoComment: videoComment,
            referenceCount: referenceImages.count,
            learnedReferenceCount: learnedReferences.count,
            hardNegativeCount: min(rejectedCount, 8),
            candidateCount: candidates.count,
            segmentCount: segments.count,
            confirmedCount: confirmedCount,
            rejectedCount: rejectedCount,
            unreviewedCount: unreviewedCount,
            reviewedPrecision: reviewedPrecision,
            rescanAddedCount: rescanAddedTotal,
            rescanConfirmedCount: rescanConfirmed,
            rescanRejectedCount: rescanRejected,
            missedSuspicionCount: rescanConfirmed,
            rescanRuns: runSummaries,
            candidateBudgetAnalysis: candidateBudgetAnalysis,
            referenceAggregationBenchmark: aggregationBenchmark,
            feedbackRescanAggregationBenchmark: feedbackAggregationBenchmark,
            maskingBenchmark: maskingBenchmark,
            foregroundReserveRerank: foregroundReserveRerankSummary,
            trackingSeedQuality: trackingSeedQualitySummary,
            objectTrackingBenchmark: objectTrackingBenchmarkSummary,
            scanPerformanceRuns: scanPerformanceRuns.isEmpty ? nil : scanPerformanceRuns,
            averageTrackingScore: averageTracking,
            positiveDistances: .make(positives),
            negativeDistances: .make(negatives),
            threshold: feedbackThreshold,
            thresholdOverlaps: feedbackHasOverlap,
            reportConfidence: confidence,
            currentSensitivity: sensitivity.rawValue,
            currentCoarseInterval: scanInterval,
            currentDetailInterval: detailInterval,
            recommendedSensitivity: recommendedSensitivity.rawValue,
            recommendedCoarseInterval: recommendedCoarse,
            recommendedDetailInterval: recommendedDetail,
            referenceEvaluations: evaluations,
            falsePositiveComments: falsePositiveComments,
            missedDetectionComments: missedComments,
            guidance: guidance
        )
    }

    private func makeMaskingBenchmark() -> MaskingBenchmarkSummary? {
        let samples: [MaskingLabeledSample] = segments.compactMap { segment in
            guard segment.discoverySource == .initial,
                  let scores = maskDiagnosticsBySegmentID[segment.id] else {
                return nil
            }
            switch segment.reviewState {
            case .confirmed:
                return MaskingLabeledSample(isConfirmed: true, scores: scores)
            case .rejected:
                return MaskingLabeledSample(isConfirmed: false, scores: scores)
            case .unreviewed:
                return nil
            }
        }

        return MaskingDiagnosticAnalyzer.benchmark(
            samples: samples,
            diagnosticElapsedSeconds: maskDiagnosticTotalElapsedSeconds > 0
                ? maskDiagnosticTotalElapsedSeconds
                : nil,
            wasThermallyLimited: maskDiagnosticWasThermallyLimited
        )
    }

    private func makeReferenceAggregationBenchmark() -> ReferenceAggregationBenchmarkSummary? {
        let samples: [ReferenceAggregationLabeledSample] = segments.compactMap { segment in
            // 学習再探索は元見本＋学習見本＋hard negativeという別条件なので混在させない。
            // 同一の初回見本集合で採点された区間だけをA/B比較する。
            guard segment.discoverySource == .initial,
                  let scores = segment.aggregationScores else { return nil }
            switch segment.reviewState {
            case .confirmed:
                return ReferenceAggregationLabeledSample(isConfirmed: true, scores: scores)
            case .rejected:
                return ReferenceAggregationLabeledSample(isConfirmed: false, scores: scores)
            case .unreviewed:
                return nil
            }
        }
        return ReferenceScoreAnalyzer.benchmark(samples: samples)
    }

    private func makeFeedbackRescanAggregationBenchmark() -> ReferenceAggregationBenchmarkSummary? {
        let samples: [ReferenceAggregationLabeledSample] = segments.compactMap { segment in
            guard segment.discoverySource == .feedbackRescan,
                  let scores = segment.aggregationScores else { return nil }
            switch segment.reviewState {
            case .confirmed:
                return ReferenceAggregationLabeledSample(isConfirmed: true, scores: scores)
            case .rejected:
                return ReferenceAggregationLabeledSample(isConfirmed: false, scores: scores)
            case .unreviewed:
                return nil
            }
        }
        return ReferenceScoreAnalyzer.benchmark(samples: samples)
    }

    private func makeCandidateBudgetAnalysis() -> CandidateBudgetAnalysisSummary? {
        guard initialCoarseReserveAnalysisAvailable,
              initialDetailCandidateBudget > 0,
              initialCoarseReserveLimit > 0 else {
            return nil
        }

        let confirmedRescan = segments.filter {
            $0.discoverySource == .feedbackRescan && $0.reviewState == .confirmed
        }
        var withinBudget = 0
        var outsideBudget = 0
        var notInReserve = 0
        var confirmedRanks: [Int?] = []

        for segment in confirmedRescan {
            let rank = CandidateBudgetAnalyzer.rankCoveringSegment(
                startTime: segment.startTime,
                endTime: segment.endTime,
                detailRadius: initialDetailRadius,
                rankedCandidates: initialCoarseReserve
            )
            confirmedRanks.append(rank)
            switch CandidateBudgetAnalyzer.attribution(
                rank: rank,
                initialDetailBudget: initialDetailCandidateBudget
            ) {
            case .withinInitialBudget:
                withinBudget += 1
            case .outsideInitialBudget:
                outsideBudget += 1
            case .notInInitialReserve:
                notInReserve += 1
            }
        }

        let standardBudgets = [12, 18, 24, 36, 48, 72, 96]
        let coverageBudgets = Array(Set(
            standardBudgets.filter { $0 <= initialCoarseReserveLimit }
            + [initialDetailCandidateBudget]
        )).sorted()
        let coverageCurve = CandidateBudgetAnalyzer.coverageCurve(
            ranks: confirmedRanks,
            budgets: coverageBudgets
        )

        let knownSegments = confirmedRescan.map {
            CandidateBudgetKnownSegment(startTime: $0.startTime, endTime: $0.endTime)
        }
        let temporalDiversity: CandidateTemporalDiversitySummary?
        if let duration = videoMetadata?.duration {
            temporalDiversity = CandidateBudgetAnalyzer.temporalDiversitySummary(
                rankedCandidates: initialCoarseReserve,
                budget: initialDetailCandidateBudget,
                duration: duration,
                detailRadius: initialDetailRadius,
                knownSegments: knownSegments,
                binCount: 6
            )
        } else {
            temporalDiversity = nil
        }

        return CandidateBudgetAnalysisSummary(
            initialDetailBudget: initialDetailCandidateBudget,
            initialReserveLimit: initialCoarseReserveLimit,
            initialReserveCount: initialCoarseReserve.count,
            rescanConfirmedCount: confirmedRescan.count,
            withinInitialBudgetCount: withinBudget,
            outsideInitialBudgetCount: outsideBudget,
            notInInitialReserveCount: notInReserve,
            coverageCurve: coverageCurve,
            temporalDiversity: temporalDiversity
        )
    }

    func recognitionQualityReportText() -> String {
        recognitionQualityReportForDisplay().textReport
    }

    func combinedDiagnosticAndRecognitionReport() -> String {
        diagnosticReport() + "\n\n==============================\n\n" + recognitionQualityReportText()
    }

    private func averageFloat(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        return values.reduce(Float(0), +) / Float(values.count)
    }

    private func makeVideoSelectionComment(reviewedPrecision: Double?) -> String {
        guard let metadata = videoMetadata else {
            return "動画未選択のため、動画選定の短評は生成できません。"
        }
        let minutes = max(metadata.duration / 60, 0.01)
        let density = Double(segments.count) / minutes
        var comments: [String] = []

        if metadata.duration >= 1800 {
            comments.append("長時間動画のため、粗探索→詳細探索の二段階方式が適しています")
        } else if metadata.duration <= 30 {
            comments.append("短い動画なので、粗探索1秒以下でも負荷は比較的小さめです")
        } else {
            comments.append("動画長は通常範囲です")
        }

        if density >= 8 {
            comments.append("候補密度が高く、誤検出抑制を優先した方が確認作業を減らせます")
        } else if density > 0 && density < 1, rescanConfirmedCountForReport > 0 {
            comments.append("対象の登場頻度が低く、粗探索間隔を短くする価値があります")
        }

        if let reviewedPrecision, reviewedPrecision < 0.5, rejectedCount >= 3 {
            comments.append("この動画では似た別対象が多く、hard negative学習が重要です")
        }
        return comments.joined(separator: "。") + "。"
    }

    private var rescanConfirmedCountForReport: Int {
        segments.filter { $0.discoverySource == .feedbackRescan && $0.reviewState == .confirmed }.count
    }

    func adjustedRange(for segment: DetectedSegment) -> (start: TimeInterval, end: TimeInterval) {
        let duration = videoMetadata?.duration ?? segment.endTime + trailPadding
        return (
            start: max(0, segment.startTime - max(0, leadPadding)),
            end: min(duration, segment.endTime + max(0, trailPadding))
        )
    }


    // MARK: - Stage 5 export

    func startExport() {
        guard !isExclusiveWorkInProgress else { return }
        guard let asset = videoAsset else {
            errorMessage = "書き出す元動画を開けません。"
            return
        }

        let ranges = mergedSelectedExportRanges
        guard !ranges.isEmpty else {
            errorMessage = "切り出し対象の候補を1区間以上選択してください。"
            return
        }

        let selectedMode = exportMode
        let selectedFormat = exportFormat
        let timestamp = exportTimestamp()

        persistRecognitionReportSnapshot(reason: "before-export")
        isExporting = true
        exportProgress = 0
        DiagnosticLogger.log("Export started: mode=\(selectedMode.rawValue), format=\(selectedFormat.rawValue), ranges=\(ranges.count)")
        exportPhase = "準備中"
        lastExportMessage = nil
        errorMessage = nil
        statusMessage = "動画を書き出しています…"

        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch selectedMode {
                case .individual:
                    for (index, range) in ranges.enumerated() {
                        try Task.checkCancellation()
                        self.exportPhase = "クリップ \(index + 1) / \(ranges.count) を書き出し中"

                        let url = try await VideoExporter.exportClip(
                            asset: asset,
                            range: range,
                            format: selectedFormat,
                            filenameStem: String(format: "VideoTargetFinder_%@_%03d", timestamp, index + 1),
                            progress: { localProgress in
                                let completed = Double(index)
                                self.exportProgress = (completed + localProgress * 0.90) / Double(ranges.count)
                            }
                        )

                        try Task.checkCancellation()
                        DiagnosticLogger.log("Safe export persisted: \(url.lastPathComponent), bytes=\(PendingExportStore.fileSize(url))")
                        self.pendingExportURLs = PendingExportStore.list()
                        self.exportProgress = Double(index + 1) / Double(ranges.count)
                    }

                    self.lastExportMessage = "\(ranges.count)本のクリップを書き出しました。下の共有ボタンから写真へ保存できます。"

                case .combined:
                    self.exportPhase = "選択区間を1本に結合中"
                    let url = try await VideoExporter.exportCombined(
                        asset: asset,
                        ranges: ranges,
                        format: selectedFormat,
                        filenameStem: "VideoTargetFinder_\(timestamp)_combined",
                        progress: { value in
                            self.exportProgress = value * 0.92
                        }
                    )

                    try Task.checkCancellation()
                    self.exportPhase = "結合動画を安全保存中"
                    let bytes = PendingExportStore.fileSize(url)
                    DiagnosticLogger.log("Safe export persisted: \(url.lastPathComponent), bytes=\(bytes)")
                    self.pendingExportURLs = PendingExportStore.list()
                    self.exportProgress = 1
                    self.lastExportMessage = "\(ranges.count)区間を結合した動画を書き出しました。下の共有ボタンから写真へ保存できます。"
                }

                self.exportPhase = "完了"
                self.statusMessage = self.lastExportMessage ?? "書き出しが完了しました。"
            } catch is CancellationError {
                self.exportPhase = "キャンセル"
                self.statusMessage = "動画の書き出しをキャンセルしました。"
            } catch {
                self.exportPhase = "エラー"
                self.presentError(error, context: "動画の書き出し")
                self.statusMessage = "動画の書き出しに失敗しました。"
            }

            self.finishExport()
        }
    }

    func refreshPendingExports() {
        pendingExportURLs = PendingExportStore.list()
    }

    func deletePendingExport(_ url: URL) {
        PendingExportStore.delete(url)
        pendingExportURLs = PendingExportStore.list()
        DiagnosticLogger.log("Pending export deleted: \(url.lastPathComponent)")
    }

    func pendingExportSizeText(_ url: URL) -> String {
        PendingExportStore.formattedSize(url)
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func makeMergedExportRanges() -> [ExportTimeRange] {
        let raw = segments
            .filter(\.isSelectedForExport)
            .map { segment -> ExportTimeRange in
                let adjusted = adjustedRange(for: segment)
                return ExportTimeRange(start: adjusted.start, end: adjusted.end)
            }
            .filter { $0.duration > 0.01 }
            .sorted { $0.start < $1.start }

        guard var current = raw.first else { return [] }
        var merged: [ExportTimeRange] = []
        let gap = max(0, exportMergeGap)

        for next in raw.dropFirst() {
            if next.start <= current.end + gap {
                current.end = max(current.end, next.end)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    private func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func finishExport() {
        isExporting = false
        exportTask = nil
    }

    private func calculateSuggestedFeedbackThreshold() -> Float? {
        let positives = segments.filter { $0.reviewState == .confirmed }.map(\.bestDistance)
        let negatives = segments.filter { $0.reviewState == .rejected }.map(\.bestDistance)

        if let positiveMax = positives.max(), let negativeMin = negatives.min() {
            return (positiveMax + negativeMin) / 2
        }
        if let positiveMax = positives.max() {
            return positiveMax + max(0.005, positiveMax * 0.03)
        }
        if let negativeMin = negatives.min() {
            return max(0, negativeMin - max(0.005, negativeMin * 0.03))
        }
        return nil
    }

    // MARK: - Stage 3 scan pipeline

    private func runCoarseScan(
        generator: AVAssetImageGenerator,
        matcher: FeaturePrintMatcher,
        duration: TimeInterval,
        interval: TimeInterval,
        sensitivity: SearchSensitivity,
        startIndex: Int,
        initialCandidates: [ScanCandidate],
        initialScores: [Float],
        enablePersistentCheckpoint: Bool,
        candidateLimit: Int? = nil,
        initialAnalysisReserve: [CandidateBudgetPoint] = [],
        analysisReserveLimit: Int? = nil,
        captureFeatureCache: Bool = false,
        reuseFeatureCache: Bool = false
    ) async throws -> (
        candidates: [ScanCandidate],
        analysisReserve: [CandidateBudgetPoint],
        threshold: Float,
        featureCacheHits: Int,
        freshFeatureSamples: Int
    ) {
        let totalFrames = max(1, Int(ceil(duration / interval)))
        let effectiveCandidateLimit = max(1, candidateLimit ?? sensitivity.coarseCandidateLimit)
        let effectiveAnalysisReserveLimit = max(
            effectiveCandidateLimit,
            analysisReserveLimit ?? effectiveCandidateLimit
        )
        var topCandidates: [ScanCandidate] = initialCandidates
        var analysisReserve = initialAnalysisReserve
        var allScores: [Float] = initialScores
        var featureCacheHits = 0
        var freshFeatureSamples = 0
        topCandidates.reserveCapacity(effectiveCandidateLimit)
        analysisReserve.reserveCapacity(effectiveAnalysisReserveLimit)
        allScores.reserveCapacity(totalFrames)

        if captureFeatureCache {
            initialCoarseFeatureCache.removeAll(keepingCapacity: true)
            initialCoarseFeatureCacheSensitivity = sensitivity
            initialCoarseFeatureCacheInterval = interval
        }

        let canReuseFeatureCache =
            reuseFeatureCache &&
            initialCoarseFeatureCacheSensitivity == sensitivity &&
            !initialCoarseFeatureCache.isEmpty

        for index in max(0, startIndex)..<totalFrames {
            try Task.checkCancellation()
            try await awaitRuntimePermission()
            let requestedSeconds = min(max(0, duration - 0.001), Double(index) * interval)
            let requestedTime = CMTime(seconds: requestedSeconds, preferredTimescale: 600)
            let cacheKey = coarseFeatureCacheKey(for: requestedSeconds)

            do {
                let match: RegionMatch
                let actualTime: TimeInterval
                let thumbnail: UIImage

                if canReuseFeatureCache, let cached = initialCoarseFeatureCache[cacheKey] {
                    match = try await matchPreparedFrame(cached.features, matcher: matcher)
                    actualTime = cached.actualTime
                    thumbnail = Self.cachedCandidatePlaceholder
                    featureCacheHits += 1
                } else {
                    let result = try await generator.image(at: requestedTime)
                    actualTime = result.actualTime.seconds
                    thumbnail = ImageMemoryTools.thumbnail(from: result.image, maxDimension: 320)
                    freshFeatureSamples += 1

                    if captureFeatureCache {
                        let prepared = try await prepareAndMatchFrame(
                            result.image,
                            matcher: matcher,
                            sensitivity: sensitivity
                        )
                        match = prepared.match
                        if initialCoarseFeatureCache.count < Self.maxInitialCoarseFeatureCacheEntries {
                            initialCoarseFeatureCache[cacheKey] = CoarseFeatureCacheEntry(
                                actualTime: actualTime,
                                features: prepared.features
                            )
                        }
                    } else {
                        match = try await matchFrame(
                            result.image,
                            matcher: matcher,
                            sensitivity: sensitivity
                        )
                    }
                }

                if match.rejectedByNegative {
                    // 負例に明確に近いフレームは候補化しない。分布計算では下位側へ送る。
                    allScores.append(match.distance + 0.25)
                } else {
                    allScores.append(match.distance)

                    let candidate = ScanCandidate(
                        time: actualTime,
                        distance: match.distance,
                        thumbnail: thumbnail,
                        referenceIndex: match.referenceIndex,
                        regionLabel: match.regionLabel
                    )
                    let minimumSpacing = max(0.75, interval * 0.75)
                    insertDistinct(
                        candidate,
                        into: &topCandidates,
                        limit: effectiveCandidateLimit,
                        minimumSpacing: minimumSpacing
                    )
                    CandidateBudgetAnalyzer.insertDistinct(
                        CandidateBudgetPoint(
                            time: actualTime,
                            distance: match.distance
                        ),
                        into: &analysisReserve,
                        limit: effectiveAnalysisReserveLimit,
                        minimumSpacing: minimumSpacing
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 単一フレームの読込/解析失敗では全体を止めない。
            }

            if index % 3 == 0 || index == totalFrames - 1 {
                scanProgress = Double(index + 1) / Double(totalFrames)
                candidates = topCandidates
                if reuseFeatureCache {
                    statusMessage = "粗探索中… \(index + 1) / \(totalFrames) フレーム（Feature再利用 \(featureCacheHits)）"
                } else {
                    statusMessage = "粗探索中… \(index + 1) / \(totalFrames) フレーム"
                }
                if enablePersistentCheckpoint, index % 30 == 0 || index == totalFrames - 1 {
                    persistCoarseCheckpoint(
                        nextFrameIndex: index + 1,
                        scores: allScores,
                        candidates: topCandidates,
                        analysisReserve: analysisReserve,
                        duration: duration,
                        coarseInterval: interval,
                        detailInterval: detailInterval,
                        sensitivity: sensitivity
                    )
                }
                await Task.yield()
            }
        }

        let threshold = ScanPipelineCore.percentile(
            allScores,
            quantile: sensitivity.candidateQuantile
        )
            ?? topCandidates.last?.distance
            ?? .greatestFiniteMagnitude

        return (
            topCandidates,
            analysisReserve,
            threshold,
            featureCacheHits,
            freshFeatureSamples
        )
    }

    private func runDetailedScan(
        generator: AVAssetImageGenerator,
        matcher: FeaturePrintMatcher,
        windows: [TimeWindow],
        interval: TimeInterval,
        sensitivity: SearchSensitivity,
        threshold: Float,
        captureFeatureCache: Bool = false,
        reuseFeatureCache: Bool = false
    ) async throws -> (
        hits: [DetailedHit],
        featureCacheHits: Int,
        freshFeatureSamples: Int
    ) {
        let totalSamples = max(1, detailSampleCount(windows: windows, interval: interval))
        var completed = 0
        var hits: [DetailedHit] = []
        var featureCacheHits = 0
        var freshFeatureSamples = 0

        if captureFeatureCache {
            initialDetailFeatureCache.removeAll(keepingCapacity: true)
            initialDetailFeatureCacheSensitivity = sensitivity
        }

        let canReuseFeatureCache =
            reuseFeatureCache &&
            initialDetailFeatureCacheSensitivity == sensitivity &&
            !initialDetailFeatureCache.isEmpty

        for window in windows {
            var t = window.start
            while t <= window.end + 0.0001 {
                try Task.checkCancellation()
                try await awaitRuntimePermission()
                let requestedTime = CMTime(seconds: t, preferredTimescale: 600)

                do {
                    let result = try await generator.image(at: requestedTime)
                    let actualTime = result.actualTime.seconds
                    let cacheKey = detailFeatureCacheKey(for: actualTime)
                    let match: RegionMatch

                    if canReuseFeatureCache, let cached = initialDetailFeatureCache[cacheKey] {
                        match = try await matchPreparedFrame(cached.features, matcher: matcher)
                        featureCacheHits += 1
                    } else if captureFeatureCache {
                        let prepared = try await prepareAndMatchFrame(
                            result.image,
                            matcher: matcher,
                            sensitivity: sensitivity
                        )
                        match = prepared.match
                        freshFeatureSamples += 1
                        if initialDetailFeatureCache.count < Self.maxInitialDetailFeatureCacheEntries {
                            initialDetailFeatureCache[cacheKey] = CoarseFeatureCacheEntry(
                                actualTime: actualTime,
                                features: prepared.features
                            )
                        }
                    } else {
                        match = try await matchFrame(
                            result.image,
                            matcher: matcher,
                            sensitivity: sensitivity
                        )
                        freshFeatureSamples += 1
                    }

                    if !match.rejectedByNegative, match.distance <= threshold {
                        let matchedCGImage = FrameRegionSampler.croppedImage(
                            from: result.image,
                            normalizedRect: match.regionNormalizedRect
                        ) ?? result.image

                        let frameThumb = ImageMemoryTools.thumbnail(from: result.image, maxDimension: 240)
                        let matchThumb = ImageMemoryTools.thumbnail(from: matchedCGImage, maxDimension: 192)
                        guard let frameData = frameThumb.jpegData(compressionQuality: 0.68),
                              let matchData = matchThumb.jpegData(compressionQuality: 0.78) else {
                            t += interval
                            completed += 1
                            continue
                        }

                        hits.append(DetailedHit(
                            time: actualTime,
                            distance: match.distance,
                            thumbnailJPEG: frameData,
                            matchThumbnailJPEG: matchData,
                            referenceIndex: match.referenceIndex,
                            regionLabel: match.regionLabel,
                            aggregationScores: match.aggregationScores
                        ))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 単一フレーム失敗は無視。
                }

                completed += 1
                if completed % 4 == 0 || completed == totalSamples {
                    scanProgress = min(1, Double(completed) / Double(totalSamples))
                    if reuseFeatureCache {
                        statusMessage = "詳細探索中… \(completed) / \(totalSamples) フレーム（Feature再利用 \(featureCacheHits)）"
                    } else {
                        statusMessage = "詳細探索中… \(completed) / \(totalSamples) フレーム"
                    }
                    await Task.yield()
                }
                t += interval
            }
        }

        return (
            hits.sorted { $0.time < $1.time },
            featureCacheHits,
            freshFeatureSamples
        )
    }

    private func buildSegments(
        from hits: [DetailedHit],
        duration: TimeInterval,
        detailInterval: TimeInterval
    ) -> [DetectedSegment] {
        let plans = ScanPipelineCore.segmentPlans(
            hits: hits.map {
                ScanPipelinePoint(time: $0.time, distance: $0.distance)
            },
            duration: duration,
            detailInterval: detailInterval
        )

        return plans.compactMap { plan in
            let group = hits[plan.hitRange]
            let best = hits[plan.bestHitIndex]

            guard let thumbnail = UIImage(data: best.thumbnailJPEG),
                  let matchThumbnail = UIImage(data: best.matchThumbnailJPEG) else { return nil }

            let diagnosticScores = ReferenceScoreAnalyzer.bestAcrossSamples(
                group.map(\.aggregationScores)
            ) ?? best.aggregationScores

            return DetectedSegment(
                startTime: plan.startTime,
                endTime: plan.endTime,
                bestTime: best.time,
                bestDistance: best.distance,
                thumbnail: thumbnail,
                matchThumbnail: matchThumbnail,
                referenceIndex: best.referenceIndex,
                regionLabel: best.regionLabel,
                hitCount: plan.hitCount,
                trackingScore: plan.trackingScore,
                aggregationScores: diagnosticScores
            )
        }
    }

    private func refreshLearnedReferencesFromConfirmedSegments() {
        // Feature Printの比較回数が増え過ぎないよう、学習見本は最大8枚。
        // 距離が小さい（元の見本に近い）正解候補から優先する。
        let confirmed = segments
            .filter { $0.reviewState == .confirmed }
            .sorted { $0.bestDistance < $1.bestDistance }
            .prefix(8)

        learnedReferences = confirmed.map { segment in
            LearnedReference(
                sourceSegmentID: segment.id,
                image: segment.matchThumbnail,
                sourceTime: segment.bestTime
            )
        }
    }

    private func mergeFeedbackRescanSegments(
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

            if !overlapsExisting {
                var taggedCandidate = candidate
                taggedCandidate.discoverySource = .feedbackRescan
                result.append(taggedCandidate)
            }
        }

        return result.sorted { $0.startTime < $1.startTime }
    }

    private func makeDetailWindows(
        from candidates: [ScanCandidate],
        duration: TimeInterval,
        radius: TimeInterval
    ) -> [TimeWindow] {
        ScanPipelineCore.mergedDetailWindows(
            candidates: candidates.map {
                ScanPipelinePoint(time: $0.time, distance: $0.distance)
            },
            duration: duration,
            radius: radius
        ).map {
            TimeWindow(start: $0.start, end: $0.end)
        }
    }

    private func insertDistinct(
        _ candidate: ScanCandidate,
        into list: inout [ScanCandidate],
        limit: Int,
        minimumSpacing: TimeInterval
    ) {
        ScanPipelineCore.insertDistinct(
            candidate,
            into: &list,
            limit: limit,
            minimumSpacing: minimumSpacing,
            time: { $0.time },
            distance: { $0.distance }
        )
    }

    private func percentile(_ values: [Float], quantile: Double) -> Float? {
        ScanPipelineCore.percentile(values, quantile: quantile)
    }

    private static func makeExactDiagnosticImageGenerator(asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    private static func makeImageGenerator(asset: AVAsset, interval: TimeInterval) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let tolerance = min(0.20, interval / 3)
        generator.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: tolerance, preferredTimescale: 600)
        return generator
    }

    // MARK: - Stage 7 runtime stability / recovery

    func pauseScan(reason: String = "手動で一時停止") {
        guard isScanning else { return }
        isScanPaused = true
        pauseReason = reason
        statusMessage = "解析を一時停止しています。再開すると続きから処理します。"
    }

    func resumeScan() {
        guard isScanning else { return }
        isScanPaused = false
        pauseReason = nil
        statusMessage = "解析を再開しました…"
    }

    /// アプリがバックグラウンドへ移る前に呼ぶ。iOSによる強制停止前に安全な待機状態へ入れる。
    func prepareForBackground() {
        if isScanning {
            pauseScan(reason: "バックグラウンド移行")
        }
    }

    /// 前回アプリ終了時に粗探索途中のチェックポイントがあれば、同じフレーム位置から続行する。
    func restoreAndResumeInterruptedScan() {
        guard !isExclusiveWorkInProgress else { return }
        isLoadingVideo = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingVideo = false }
            do {
                let access = await self.preparePhotoLibraryAccess()
                guard access else { return }

                let (checkpoint, restoredReferences) = try ScanCheckpointStore.load()
                guard !restoredReferences.isEmpty else {
                    throw RecoveryError.missingReferenceImages
                }

                let asset = try await self.requestAVAsset(localIdentifier: checkpoint.videoAssetIdentifier)
                let metadata = try await self.makeMetadata(from: asset)
                let referenceCGImages = restoredReferences.compactMap { $0.normalizedCGImage() }
                guard !referenceCGImages.isEmpty else { throw RecoveryError.missingReferenceImages }

                self.videoAsset = asset
                self.videoMetadata = metadata
                self.videoAssetIdentifier = checkpoint.videoAssetIdentifier
                self.referenceImages = Array(restoredReferences.prefix(5))
                self.scanInterval = checkpoint.coarseInterval
                self.detailInterval = checkpoint.detailInterval
                self.sensitivity = checkpoint.sensitivity
                self.errorMessage = nil
                self.isScanning = true
                self.isScanPaused = false
                self.pauseReason = nil
                self.scanPhase = "復旧中"
                self.scanProgress = min(1, Double(checkpoint.nextFrameIndex) / Double(max(1, Int(ceil(metadata.duration / checkpoint.coarseInterval)))))
                self.statusMessage = "前回の粗探索を \(self.scanProgress.formatted(.percent.precision(.fractionLength(0)))) から再開します…"
                self.checkpointReferencesWritten = true
                let detailCandidateBudget = checkpoint.sensitivity.coarseCandidateLimit
                let analysisReserveLimit = max(48, detailCandidateBudget * 4)
                self.initialDetailCandidateBudget = detailCandidateBudget
                self.initialCoarseReserveLimit = analysisReserveLimit
                self.initialDetailRadius = checkpoint.sensitivity.detailRadius
                self.initialScanSensitivity = checkpoint.sensitivity
                self.initialCoarseReserveAnalysisAvailable = checkpoint.analysisReserve != nil

                let restoredCandidates = checkpoint.candidates.prefix(detailCandidateBudget).map {
                    ScanCandidate(
                        time: $0.time,
                        distance: $0.distance,
                        thumbnail: ImageMemoryTools.placeholder(),
                        referenceIndex: $0.referenceIndex,
                        regionLabel: $0.regionLabel
                    )
                }
                let restoredAnalysisReserve = checkpoint.analysisReserve?.map {
                    CandidateBudgetPoint(time: $0.time, distance: $0.distance)
                } ?? []

                self.scanTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let matcher = try FeaturePrintMatcher(referenceImages: referenceCGImages)
                        let generator = Self.makeImageGenerator(asset: asset, interval: checkpoint.coarseInterval)
                        self.scanPhase = "粗探索を再開"
                        var performancePhases: [ScanPhasePerformanceSummary] = []
                        let coarsePerformanceStart = self.beginPerformancePhase()
                        let coarsePlannedSamples = self.coarseSampleCount(
                            duration: metadata.duration,
                            interval: checkpoint.coarseInterval,
                            startIndex: checkpoint.nextFrameIndex
                        )

                        let coarse = try await self.runCoarseScan(
                            generator: generator,
                            matcher: matcher,
                            duration: metadata.duration,
                            interval: checkpoint.coarseInterval,
                            sensitivity: checkpoint.sensitivity,
                            startIndex: checkpoint.nextFrameIndex,
                            initialCandidates: restoredCandidates,
                            initialScores: checkpoint.scores,
                            enablePersistentCheckpoint: true,
                            initialAnalysisReserve: restoredAnalysisReserve,
                            analysisReserveLimit: analysisReserveLimit
                        )
                        performancePhases.append(
                            self.finishPerformancePhase(
                                phase: .coarse,
                                startedAt: coarsePerformanceStart,
                                sampleCount: coarsePlannedSamples,
                                outputCount: coarse.candidates.count
                            )
                        )
                        self.recordPerformanceRun(kind: .recovery, runNumber: nil, phases: performancePhases)

                        self.initialCoarseReserve = coarse.analysisReserve
                        self.candidates = coarse.candidates
                        self.adaptiveThreshold = coarse.threshold
                        let recoveredCandidatePoints = coarse.candidates.map {
                            CandidateBudgetPoint(time: $0.time, distance: $0.distance)
                        }
                        let reservePrefixVerified = CandidateBudgetAnalyzer.prefixMatches(
                            normalCandidates: recoveredCandidatePoints,
                            rankedReserve: coarse.analysisReserve
                        )
                        self.initialCoarseReserveAnalysisAvailable =
                            checkpoint.analysisReserve != nil && reservePrefixVerified
                        DiagnosticLogger.log(
                            "Recovered coarse reserve: retained=\(coarse.analysisReserve.count)/\(analysisReserveLimit), prefixVerified=\(reservePrefixVerified), hadSavedReserve=\(checkpoint.analysisReserve != nil)"
                        )
                        try Task.checkCancellation()

                        guard !coarse.candidates.isEmpty else {
                            ScanCheckpointStore.clear()
                            self.hasRecoverableScan = false
                            self.scanProgress = 1
                            self.scanPhase = "完了"
                            self.statusMessage = "復旧した粗探索が完了しましたが、候補はありませんでした。"
                            self.finishScan()
                            return
                        }

                        self.scanPhase = "詳細探索"
                        self.scanProgress = 0
                        let fineInterval = min(0.5, max(0.10, checkpoint.detailInterval))
                        let detailGenerator = Self.makeImageGenerator(asset: asset, interval: fineInterval)
                        let windows = self.makeDetailWindows(
                            from: coarse.candidates,
                            duration: metadata.duration,
                            radius: checkpoint.sensitivity.detailRadius
                        )
                        let detailThreshold = ScanPipelineCore.detailThreshold(coarseThreshold: coarse.threshold)
                        let detailPlannedSamples = self.detailSampleCount(windows: windows, interval: fineInterval)
                        let detailPerformanceStart = self.beginPerformancePhase()
                        let detail = try await self.runDetailedScan(
                            generator: detailGenerator,
                            matcher: matcher,
                            windows: windows,
                            interval: fineInterval,
                            sensitivity: checkpoint.sensitivity,
                            threshold: detailThreshold
                        )
                        performancePhases.append(
                            self.finishPerformancePhase(
                                phase: .detail,
                                startedAt: detailPerformanceStart,
                                sampleCount: detailPlannedSamples,
                                outputCount: detail.hits.count
                            )
                        )
                        self.recordPerformanceRun(kind: .recovery, runNumber: nil, phases: performancePhases)

                        self.segments = self.buildSegments(
                            from: detail.hits,
                            duration: metadata.duration,
                            detailInterval: fineInterval
                        )
                        ScanCheckpointStore.clear()
                        self.hasRecoverableScan = false
                        self.scanProgress = 1
                        self.scanPhase = "完了"
                        self.statusMessage = "復旧解析が完了しました。\(self.segments.count)個の候補区間を作成しました。"
                    } catch is CancellationError {
                        self.scanPhase = "キャンセル"
                        self.statusMessage = "復旧解析をキャンセルしました。チェックポイントは保持しています。"
                    } catch {
                        self.errorMessage = error.localizedDescription
                        self.scanPhase = "エラー"
                        self.statusMessage = "復旧解析に失敗しました。チェックポイントは保持しています。"
                    }
                    self.finishScan()
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "前回の解析を復旧できませんでした。"
                self.hasRecoverableScan = ScanCheckpointStore.exists
            }
        }
    }

    func discardRecoverableScan() {
        guard !isExclusiveWorkInProgress else { return }
        ScanCheckpointStore.clear()
        hasRecoverableScan = false
        statusMessage = "前回の解析チェックポイントを削除しました。"
    }

    private func currentThermalLevel() -> ScanPerformanceThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    private func beginPerformancePhase() -> Date {
        currentPhaseThermalPeak = currentThermalLevel()
        return Date()
    }

    private func finishPerformancePhase(
        phase: ScanPerformancePhaseKind,
        startedAt: Date,
        sampleCount: Int,
        outputCount: Int
    ) -> ScanPhasePerformanceSummary {
        ScanPhasePerformanceSummary(
            phase: phase,
            elapsedSeconds: max(0, Date().timeIntervalSince(startedAt)),
            sampleCount: max(0, sampleCount),
            outputCount: max(0, outputCount),
            thermalPeak: currentPhaseThermalPeak
        )
    }

    private func recordPerformanceRun(
        kind: ScanPerformanceRunKind,
        runNumber: Int?,
        phases: [ScanPhasePerformanceSummary]
    ) {
        guard !phases.isEmpty else { return }
        let summary = ScanPerformanceRunSummary(kind: kind, runNumber: runNumber, phases: phases)
        if let index = scanPerformanceRuns.firstIndex(where: {
            $0.kind == kind && $0.runNumber == runNumber
        }) {
            scanPerformanceRuns[index] = summary
        } else {
            scanPerformanceRuns.append(summary)
        }
        let phaseSummary = phases.map {
            "\($0.phase.displayName)=\($0.elapsedText), samples=\($0.sampleCount), output=\($0.outputCount), thermal=\($0.thermalPeak.displayName)"
        }.joined(separator: " / ")
        DiagnosticLogger.log("Performance \(summary.title): \(phaseSummary)")
    }

    private func coarseSampleCount(
        duration: TimeInterval,
        interval: TimeInterval,
        startIndex: Int
    ) -> Int {
        guard duration.isFinite, duration > 0, interval.isFinite, interval > 0 else { return 0 }
        let total = max(1, Int(ceil(duration / interval)))
        return max(0, total - max(0, startIndex))
    }

    private func detailSampleCount(
        windows: [TimeWindow],
        interval: TimeInterval
    ) -> Int {
        guard interval.isFinite, interval > 0 else { return 0 }
        return windows.reduce(0) { partial, window in
            partial + ScanPerformanceAnalyzer.detailSampleCount(
                span: max(0, window.end - window.start),
                interval: interval
            )
        }
    }

    private func awaitRuntimePermission() async throws {
        while isScanPaused {
            try Task.checkCancellation()
            refreshThermalState()
            try await Task.sleep(for: .milliseconds(250))
        }

        refreshThermalState()
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            isScanPaused = true
            pauseReason = "端末温度が高すぎるため自動停止"
            statusMessage = "iPhoneの温度が高いため解析を自動停止しました。温度が下がってから再開してください。"
            while isScanPaused {
                try Task.checkCancellation()
                refreshThermalState()
                if ProcessInfo.processInfo.thermalState != .critical {
                    // 自動停止は温度が下がっても勝手に再開せず、ユーザー操作を待つ。
                    pauseReason = "温度が下がりました。再開できます"
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        case .serious:
            try await Task.sleep(for: .milliseconds(220))
        case .fair:
            try await Task.sleep(for: .milliseconds(60))
        case .nominal:
            break
        @unknown default:
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func refreshThermalState() {
        let level = currentThermalLevel()
        thermalStateText = level.displayName
        if isScanning {
            currentPhaseThermalPeak = ScanPerformanceThermalLevel.peak(
                currentPhaseThermalPeak,
                level
            )
        }
    }

    private func matchFrame(
        _ image: CGImage,
        matcher: FeaturePrintMatcher,
        sensitivity: SearchSensitivity
    ) async throws -> RegionMatch {
        let box = SendableCGImageBox(image)
        return try await Task.detached(priority: .utility) {
            try autoreleasepool {
                try matcher.bestMatch(in: box.image, mode: sensitivity)
            }
        }.value
    }

    private func prepareAndMatchFrame(
        _ image: CGImage,
        matcher: FeaturePrintMatcher,
        sensitivity: SearchSensitivity
    ) async throws -> (features: PreparedFrameFeatures, match: RegionMatch) {
        let box = SendableCGImageBox(image)
        return try await Task.detached(priority: .utility) {
            try autoreleasepool {
                let features = try matcher.prepareFeatures(in: box.image, mode: sensitivity)
                let match = try matcher.bestMatch(in: features)
                return (features, match)
            }
        }.value
    }

    private func matchPreparedFrame(
        _ features: PreparedFrameFeatures,
        matcher: FeaturePrintMatcher
    ) async throws -> RegionMatch {
        try await Task.detached(priority: .utility) {
            try autoreleasepool {
                try matcher.bestMatch(in: features)
            }
        }.value
    }

    private func coarseFeatureCacheKey(for requestedSeconds: TimeInterval) -> Int {
        Int((requestedSeconds * 1_000).rounded())
    }

    private func detailFeatureCacheKey(for actualSeconds: TimeInterval) -> Int {
        Int((actualSeconds * 1_000).rounded())
    }

    private func hydrateCandidateThumbnails(
        _ candidates: [ScanCandidate],
        asset: AVAsset,
        interval: TimeInterval
    ) async -> [ScanCandidate] {
        guard !candidates.isEmpty else { return candidates }
        let generator = Self.makeImageGenerator(asset: asset, interval: interval)
        var hydrated: [ScanCandidate] = []
        hydrated.reserveCapacity(candidates.count)

        for candidate in candidates {
            try? Task.checkCancellation()
            let requestedTime = CMTime(seconds: candidate.time, preferredTimescale: 600)
            do {
                let result = try await generator.image(at: requestedTime)
                hydrated.append(
                    ScanCandidate(
                        time: candidate.time,
                        distance: candidate.distance,
                        thumbnail: ImageMemoryTools.thumbnail(from: result.image, maxDimension: 320),
                        referenceIndex: candidate.referenceIndex,
                        regionLabel: candidate.regionLabel
                    )
                )
            } catch {
                hydrated.append(candidate)
            }
        }
        return hydrated
    }

    private func persistCoarseCheckpoint(
        nextFrameIndex: Int,
        scores: [Float],
        candidates: [ScanCandidate],
        analysisReserve: [CandidateBudgetPoint],
        duration: TimeInterval,
        coarseInterval: TimeInterval,
        detailInterval: TimeInterval,
        sensitivity: SearchSensitivity
    ) {
        guard let videoAssetIdentifier else { return }
        let persisted = PersistedScanCheckpoint(
            version: 2,
            videoAssetIdentifier: videoAssetIdentifier,
            duration: duration,
            coarseInterval: coarseInterval,
            detailInterval: detailInterval,
            sensitivityRawValue: sensitivity.rawValue,
            nextFrameIndex: nextFrameIndex,
            scores: scores,
            candidates: candidates.map {
                PersistedCandidate(
                    time: $0.time,
                    distance: $0.distance,
                    referenceIndex: $0.referenceIndex,
                    regionLabel: $0.regionLabel
                )
            },
            analysisReserve: analysisReserve.map {
                PersistedCandidateBudgetPoint(
                    time: $0.time,
                    distance: $0.distance
                )
            },
            createdAt: Date()
        )

        do {
            try ScanCheckpointStore.save(
                checkpoint: persisted,
                referenceImages: referenceImages,
                writeReferences: !checkpointReferencesWritten
            )
            checkpointReferencesWritten = true
            hasRecoverableScan = true
        } catch {
            // チェックポイント保存失敗は解析そのものを止めない。
        }
    }

    enum RecoveryError: LocalizedError {
        case missingReferenceImages

        var errorDescription: String? {
            switch self {
            case .missingReferenceImages:
                return "前回の見本画像を復元できませんでした。新しく見本画像を選択してください。"
            }
        }
    }

    // MARK: - Video loading

    private func requestAVAsset(localIdentifier: String) async throws -> AVAsset {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let photoAsset = result.firstObject else {
            throw VideoLoadError.assetNotFound
        }

        DiagnosticLogger.log(
            "PhotoKit asset found: duration=\(photoAsset.duration), pixels=\(photoAsset.pixelWidth)x\(photoAsset.pixelHeight)"
        )

        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.version = .current
        options.isNetworkAccessAllowed = true

        DiagnosticLogger.log("PhotoKit requestPlayerItem: invoking API")
        return try await withCheckedThrowingContinuation { continuation in
            let gate = PlayerItemContinuationGate(continuation)
            let requestID = PHImageManager.default().requestPlayerItem(forVideo: photoAsset, options: options) { playerItem, info in
                Task { @MainActor in
                    if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                        DiagnosticLogger.log("PhotoKit requestPlayerItem callback: cancelled")
                        gate.fail(CancellationError())
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        DiagnosticLogger.log("PhotoKit requestPlayerItem callback: error=\(error.localizedDescription)")
                        gate.fail(error)
                        return
                    }
                    guard let playerItem else {
                        DiagnosticLogger.log("PhotoKit requestPlayerItem callback: playerItem=nil")
                        gate.fail(VideoLoadError.noAVAsset)
                        return
                    }
                    DiagnosticLogger.log("PhotoKit requestPlayerItem callback: success")
                    gate.succeed(playerItem.asset)
                }
            }
            DiagnosticLogger.log("PhotoKit requestPlayerItem: requestID=\(requestID)")
        }
    }

    private func makeMetadata(from asset: AVAsset) async throws -> VideoMetadata {
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VideoLoadError.invalidDuration
        }

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw VideoLoadError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)

        let transformed = naturalSize.applying(preferredTransform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw VideoLoadError.invalidDimensions
        }

        return VideoMetadata(
            duration: durationSeconds,
            displaySize: CGSize(width: width, height: height),
            nominalFrameRate: nominalFrameRate.isFinite ? nominalFrameRate : 0
        )
    }

    private func currentSettings() -> AppSettings {
        AppSettings(
            scanInterval: scanInterval,
            detailInterval: detailInterval,
            feedbackRescanInterval: feedbackRescanInterval,
            sensitivityRawValue: sensitivity.rawValue,
            leadPadding: leadPadding,
            trailPadding: trailPadding,
            exportMergeGap: exportMergeGap,
            exportModeRawValue: exportMode.rawValue,
            exportFormatRawValue: exportFormat.rawValue
        )
    }

    private func persistSettings() {
        guard !isRestoringSettings else { return }
        AppSettingsStore.save(currentSettings())
    }

    private func presentError(_ error: Error, context: String?) {
        let issue = UserFacingError.map(error, context: context)
        var text = issue.message
        if let recovery = issue.recovery {
            text += "\n\n" + recovery
        }
        errorMessage = text
        DiagnosticLogger.log("ERROR [\(issue.title)] \(error.localizedDescription)")
    }

    private func resetResults() {
        candidates = []
        segments = []
        adaptiveThreshold = nil
        feedbackThreshold = nil
        learnedReferences = []
        lastFeedbackRescanAddedCount = 0
        feedbackRescanRuns = []
        initialCoarseFeatureCache = [:]
        initialDetailFeatureCache = [:]
        initialDetailFeatureCacheSensitivity = nil
        initialCoarseFeatureCacheSensitivity = nil
        initialCoarseFeatureCacheInterval = nil
        initialCoarseReserve = []
        initialDetailCandidateBudget = 0
        initialCoarseReserveLimit = 0
        initialDetailRadius = 0
        initialCoarseReserveAnalysisAvailable = false
        scanPerformanceRuns = []
        maskDiagnosticsBySegmentID = [:]
        maskDiagnosticTotalElapsedSeconds = 0
        maskDiagnosticWasThermallyLimited = false
        isPreparingMaskDiagnostics = false
        foregroundReserveDiagnosticTask?.cancel()
        foregroundReserveDiagnosticTask = nil
        foregroundReserveRerankSummary = nil
        foregroundReserveDiagnosticProgress = 0
        isRunningForegroundReserveDiagnostic = false
        initialScanSensitivity = nil
        trackingSeedDiagnosticTask?.cancel()
        trackingSeedDiagnosticTask = nil
        trackingSeedQualitySummary = nil
        trackingSeedDiagnosticProgress = 0
        isRunningTrackingSeedDiagnostic = false
        objectTrackingDiagnosticTask?.cancel()
        objectTrackingDiagnosticTask = nil
        objectTrackingBenchmarkSummary = nil
        objectTrackingDiagnosticProgress = 0
        isRunningObjectTrackingDiagnostic = false
        currentPhaseThermalPeak = .nominal
        scanProgress = 0
        scanPhase = "待機"
        isScanPaused = false
        pauseReason = nil
        lastExportMessage = nil
        if !isExporting {
            exportProgress = 0
            exportPhase = "待機"
        }
    }

    private func finishScan() {
        isScanning = false
        isScanPaused = false
        pauseReason = nil
        scanTask = nil
        refreshThermalState()
        hasRecoverableScan = ScanCheckpointStore.exists
    }

    private struct TimeWindow {
        var start: TimeInterval
        var end: TimeInterval
    }

    enum VideoLoadError: LocalizedError {
        case assetNotFound
        case noAVAsset
        case noVideoTrack
        case invalidDuration
        case invalidDimensions

        var errorDescription: String? {
            switch self {
            case .assetNotFound:
                return "選択した動画を写真ライブラリから取得できませんでした。"
            case .noAVAsset:
                return "動画をAVAssetとして開けませんでした。"
            case .noVideoTrack:
                return "動画トラックが見つかりませんでした。"
            case .invalidDuration:
                return "動画の長さを正しく取得できませんでした。別の動画で試すか、動画を一度写真アプリで編集・保存してから再度選択してください。"
            case .invalidDimensions:
                return "動画の解像度を正しく取得できませんでした。"
            }
        }
    }
}
