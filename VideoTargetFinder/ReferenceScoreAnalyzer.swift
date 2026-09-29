import Foundation

/// 1枚の動画cropに対し、元の見本画像ごとに最良distanceを1つずつ残して比較する診断値。
/// 本番の採否は従来どおり nearest を使い、この値はA/B評価専用。
struct ReferenceAggregationScores: Sendable {
    let sourceCount: Int
    let nearest: Float
    let top2Mean: Float
    let median: Float
}

struct ReferenceAggregationLabeledSample: Sendable {
    let isConfirmed: Bool
    let scores: ReferenceAggregationScores
}

struct ReferenceAggregationSeparation: Sendable, Codable {
    let confirmedCount: Int
    let rejectedCount: Int
    let confirmedMean: Float?
    let rejectedMean: Float?
    /// lower is more similarなので、rejectedMean - confirmedMean が大きいほど平均上の分離が広い。
    let meanGap: Float?
    /// confirmedの最大distanceがrejectedの最小distance以上なら分布が重なる。
    let overlaps: Bool?

    var compactText: String {
        let p = confirmedMean.map { String(format: "%.4f", $0) } ?? "n/a"
        let n = rejectedMean.map { String(format: "%.4f", $0) } ?? "n/a"
        let gap = meanGap.map { String(format: "%+.4f", $0) } ?? "n/a"
        let overlap = overlaps.map { $0 ? "YES" : "NO" } ?? "n/a"
        return "正解平均 \(p) / 誤検出平均 \(n) / gap \(gap) / overlap \(overlap)"
    }
}

struct ReferenceAggregationBenchmarkSummary: Sendable, Codable {
    let sampleCount: Int
    let confirmedCount: Int
    let rejectedCount: Int
    let nearest: ReferenceAggregationSeparation
    let top2Mean: ReferenceAggregationSeparation
    let median: ReferenceAggregationSeparation

    var scopeNote: String {
        "初回のnearest方式で詳細候補になった判定済み区間だけを、同じ見本集合で比較した診断です。学習再探索は含まず、動画全体のrecall比較でもありません。"
    }
}

enum ReferenceScoreAnalyzer {
    static func summarize(sourceDistances: [Float]) -> ReferenceAggregationScores? {
        let values = sourceDistances.filter { $0.isFinite }.sorted()
        guard let nearest = values.first else { return nil }

        let topCount = min(2, values.count)
        let top2Mean = values.prefix(topCount).reduce(Float(0), +) / Float(topCount)

        let middle = values.count / 2
        let median: Float
        if values.count.isMultiple(of: 2) {
            median = (values[middle - 1] + values[middle]) / 2
        } else {
            median = values[middle]
        }

        return ReferenceAggregationScores(
            sourceCount: values.count,
            nearest: nearest,
            top2Mean: top2Mean,
            median: median
        )
    }

    /// 同じ候補内の複数crop/複数時刻から、各集約戦略ごとに独立した最良値を取る。
    /// production nearest が選んだ1つのcrop/時刻へ他方式を従属させないための診断専用処理。
    static func bestAcrossSamples(_ samples: [ReferenceAggregationScores]) -> ReferenceAggregationScores? {
        guard let first = samples.first else { return nil }
        return ReferenceAggregationScores(
            sourceCount: samples.map(\.sourceCount).min() ?? first.sourceCount,
            nearest: samples.map(\.nearest).min() ?? first.nearest,
            top2Mean: samples.map(\.top2Mean).min() ?? first.top2Mean,
            median: samples.map(\.median).min() ?? first.median
        )
    }

    static func separation(confirmed: [Float], rejected: [Float]) -> ReferenceAggregationSeparation {
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

        return ReferenceAggregationSeparation(
            confirmedCount: confirmed.count,
            rejectedCount: rejected.count,
            confirmedMean: confirmedMean,
            rejectedMean: rejectedMean,
            meanGap: gap,
            overlaps: overlaps
        )
    }

    static func benchmark(samples: [ReferenceAggregationLabeledSample]) -> ReferenceAggregationBenchmarkSummary? {
        guard !samples.isEmpty else { return nil }

        func split(_ value: (ReferenceAggregationScores) -> Float) -> ([Float], [Float]) {
            var confirmed: [Float] = []
            var rejected: [Float] = []
            for sample in samples {
                if sample.isConfirmed {
                    confirmed.append(value(sample.scores))
                } else {
                    rejected.append(value(sample.scores))
                }
            }
            return (confirmed, rejected)
        }

        let nearestValues = split { $0.nearest }
        let top2Values = split { $0.top2Mean }
        let medianValues = split { $0.median }

        return ReferenceAggregationBenchmarkSummary(
            sampleCount: samples.count,
            confirmedCount: nearestValues.0.count,
            rejectedCount: nearestValues.1.count,
            nearest: separation(confirmed: nearestValues.0, rejected: nearestValues.1),
            top2Mean: separation(confirmed: top2Values.0, rejected: top2Values.1),
            median: separation(confirmed: medianValues.0, rejected: medianValues.1)
        )
    }

    private static func average(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        return values.reduce(Float(0), +) / Float(values.count)
    }
}
