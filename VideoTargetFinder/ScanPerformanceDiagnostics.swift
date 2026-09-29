import Foundation

enum ScanPerformanceThermalLevel: String, Sendable, Codable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    var displayName: String {
        switch self {
        case .nominal: return "通常"
        case .fair: return "やや高温"
        case .serious: return "高温・速度抑制"
        case .critical: return "危険・自動停止"
        case .unknown: return "不明"
        }
    }

    private var severity: Int {
        switch self {
        case .unknown: return -1
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    static func peak(_ lhs: ScanPerformanceThermalLevel, _ rhs: ScanPerformanceThermalLevel) -> ScanPerformanceThermalLevel {
        lhs.severity >= rhs.severity ? lhs : rhs
    }
}

enum ScanPerformanceRunKind: String, Sendable, Codable {
    case initial
    case feedbackRescan
    case recovery

    var displayName: String {
        switch self {
        case .initial: return "初回探索"
        case .feedbackRescan: return "学習再探索"
        case .recovery: return "復旧解析"
        }
    }
}

enum ScanPerformancePhaseKind: String, Sendable, Codable {
    case coarse
    case detail

    var displayName: String {
        switch self {
        case .coarse: return "粗探索"
        case .detail: return "詳細探索"
        }
    }

    var outputLabel: String {
        switch self {
        case .coarse: return "候補"
        case .detail: return "ヒット"
        }
    }
}

struct ScanPhasePerformanceSummary: Sendable, Codable, Equatable {
    let phase: ScanPerformancePhaseKind
    let elapsedSeconds: Double
    let sampleCount: Int
    let outputCount: Int
    let thermalPeak: ScanPerformanceThermalLevel

    var samplesPerSecond: Double? {
        guard elapsedSeconds > 0, sampleCount > 0 else { return nil }
        return Double(sampleCount) / elapsedSeconds
    }

    var elapsedText: String {
        String(format: "%.1f秒", max(0, elapsedSeconds))
    }

    var rateText: String {
        guard let samplesPerSecond else { return "n/a" }
        return String(format: "%.2f sample/s", samplesPerSecond)
    }
}

struct ScanPerformanceRunSummary: Sendable, Codable, Equatable, Identifiable {
    let kind: ScanPerformanceRunKind
    let runNumber: Int?
    let phases: [ScanPhasePerformanceSummary]

    var id: String {
        "\(kind.rawValue)-\(runNumber ?? 0)"
    }

    var title: String {
        if kind == .feedbackRescan, let runNumber {
            return "\(kind.displayName) #\(runNumber)"
        }
        return kind.displayName
    }

    var totalElapsedSeconds: Double {
        phases.reduce(0) { $0 + max(0, $1.elapsedSeconds) }
    }

    var peakThermalLevel: ScanPerformanceThermalLevel {
        phases.reduce(.unknown) { ScanPerformanceThermalLevel.peak($0, $1.thermalPeak) }
    }
}


enum ScanPerformanceAnalyzer {
    /// runDetailedScan の while t <= end + 0.0001 と同じ境界条件で予定sample数を求める。
    static func detailSampleCount(
        span: TimeInterval,
        interval: TimeInterval,
        tolerance: TimeInterval = 0.0001
    ) -> Int {
        guard span.isFinite, span >= 0, interval.isFinite, interval > 0 else { return 0 }
        let safeTolerance = max(0, tolerance)
        return max(1, Int(floor((span + safeTolerance) / interval)) + 1)
    }
}
