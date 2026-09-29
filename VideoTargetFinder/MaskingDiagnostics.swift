import Foundation

struct MaskStrategyCandidateResult: Sendable {
    let allInstancesDistance: Float?
    let bestSingleDistance: Float?
    let instanceCount: Int
    let evaluatedSingleCount: Int
    let requestFailed: Bool
}

struct CandidateMaskDiagnosticScores: Sendable {
    let baselineDistance: Float
    let foreground: MaskStrategyCandidateResult
    let person: MaskStrategyCandidateResult
}

struct MaskingLabeledSample: Sendable {
    let isConfirmed: Bool
    let scores: CandidateMaskDiagnosticScores
}

struct MaskDistanceSeparation: Sendable, Codable, Equatable {
    let confirmedCount: Int
    let rejectedCount: Int
    let confirmedMean: Float?
    let rejectedMean: Float?
    let meanGap: Float?
    let overlaps: Bool?

    var compactText: String {
        let p = confirmedMean.map { String(format: "%.4f", $0) } ?? "n/a"
        let n = rejectedMean.map { String(format: "%.4f", $0) } ?? "n/a"
        let gap = meanGap.map { String(format: "%+.4f", $0) } ?? "n/a"
        let overlap = overlaps.map { $0 ? "YES" : "NO" } ?? "n/a"
        return "正解平均 \(p) / 誤検出平均 \(n) / gap \(gap) / overlap \(overlap)"
    }
}

struct MaskingPairedStrategySummary: Sendable, Codable, Equatable {
    let title: String
    let availableSampleCount: Int
    let confirmedCount: Int
    let rejectedCount: Int
    let baseline: MaskDistanceSeparation
    let masked: MaskDistanceSeparation
    let meanGapDelta: Float?

    var gapDeltaText: String {
        meanGapDelta.map { String(format: "%+.4f", $0) } ?? "n/a"
    }
}

struct MaskingBenchmarkSummary: Sendable, Codable, Equatable {
    let attemptedReviewedCount: Int
    let foregroundRequestFailureCount: Int
    let personRequestFailureCount: Int
    let foregroundSingleTruncatedCandidateCount: Int
    let personSingleTruncatedCandidateCount: Int
    let foregroundUnion: MaskingPairedStrategySummary
    let foregroundBestSingle: MaskingPairedStrategySummary
    let personBestSingle: MaskingPairedStrategySummary
    let diagnosticElapsedSeconds: Double?
    let wasThermallyLimited: Bool

    var scopeNote: String {
        "初回探索で既に候補化され、○/×判定された局所画像だけのpaired A/Bです。baselineも同じmatchThumbnailから再計算し、mask側も画角・対象サイズを変えません。単一instanceは候補ごとに最大8個まで比較します。maskで新しい未検出場面を拾えるかというrecallは評価しません。"
    }
}

enum MaskingDiagnosticAnalyzer {
    static func separation(confirmed: [Float], rejected: [Float]) -> MaskDistanceSeparation {
        let confirmedMean = average(confirmed)
        let rejectedMean = average(rejected)
        let gap: Float?
        if let confirmedMean, let rejectedMean {
            gap = rejectedMean - confirmedMean
        } else {
            gap = nil
        }

        let overlaps: Bool?
        if let confirmedMax = confirmed.max(), let rejectedMin = rejected.min() {
            overlaps = confirmedMax >= rejectedMin
        } else {
            overlaps = nil
        }

        return MaskDistanceSeparation(
            confirmedCount: confirmed.count,
            rejectedCount: rejected.count,
            confirmedMean: confirmedMean,
            rejectedMean: rejectedMean,
            meanGap: gap,
            overlaps: overlaps
        )
    }

    static func benchmark(
        samples: [MaskingLabeledSample],
        diagnosticElapsedSeconds: Double?,
        wasThermallyLimited: Bool
    ) -> MaskingBenchmarkSummary? {
        guard !samples.isEmpty else { return nil }

        let foregroundUnion = pairedStrategy(
            title: "前景全体（背景除去）",
            samples: samples
        ) { $0.foreground.allInstancesDistance }

        let foregroundSingle = pairedStrategy(
            title: "前景の単一instance最良",
            samples: samples
        ) { $0.foreground.bestSingleDistance }

        let personSingle = pairedStrategy(
            title: "人物の単一instance最良",
            samples: samples
        ) { $0.person.bestSingleDistance }

        return MaskingBenchmarkSummary(
            attemptedReviewedCount: samples.count,
            foregroundRequestFailureCount: samples.filter { $0.scores.foreground.requestFailed }.count,
            personRequestFailureCount: samples.filter { $0.scores.person.requestFailed }.count,
            foregroundSingleTruncatedCandidateCount: samples.filter {
                $0.scores.foreground.instanceCount > $0.scores.foreground.evaluatedSingleCount
            }.count,
            personSingleTruncatedCandidateCount: samples.filter {
                $0.scores.person.instanceCount > $0.scores.person.evaluatedSingleCount
            }.count,
            foregroundUnion: foregroundUnion,
            foregroundBestSingle: foregroundSingle,
            personBestSingle: personSingle,
            diagnosticElapsedSeconds: diagnosticElapsedSeconds,
            wasThermallyLimited: wasThermallyLimited
        )
    }

    private static func pairedStrategy(
        title: String,
        samples: [MaskingLabeledSample],
        maskedValue: (CandidateMaskDiagnosticScores) -> Float?
    ) -> MaskingPairedStrategySummary {
        var baselineConfirmed: [Float] = []
        var baselineRejected: [Float] = []
        var maskedConfirmed: [Float] = []
        var maskedRejected: [Float] = []

        for sample in samples {
            guard let maskedDistance = maskedValue(sample.scores) else { continue }
            if sample.isConfirmed {
                baselineConfirmed.append(sample.scores.baselineDistance)
                maskedConfirmed.append(maskedDistance)
            } else {
                baselineRejected.append(sample.scores.baselineDistance)
                maskedRejected.append(maskedDistance)
            }
        }

        let baseline = separation(confirmed: baselineConfirmed, rejected: baselineRejected)
        let masked = separation(confirmed: maskedConfirmed, rejected: maskedRejected)
        let delta: Float?
        if let maskedGap = masked.meanGap, let baselineGap = baseline.meanGap {
            delta = maskedGap - baselineGap
        } else {
            delta = nil
        }

        return MaskingPairedStrategySummary(
            title: title,
            availableSampleCount: maskedConfirmed.count + maskedRejected.count,
            confirmedCount: maskedConfirmed.count,
            rejectedCount: maskedRejected.count,
            baseline: baseline,
            masked: masked,
            meanGapDelta: delta
        )
    }

    private static func average(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        return values.reduce(Float(0), +) / Float(values.count)
    }
}
