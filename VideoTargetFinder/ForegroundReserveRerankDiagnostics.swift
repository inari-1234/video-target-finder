import Foundation

struct ForegroundReserveRerankPoint: Sendable, Equatable {
    let time: TimeInterval
    let baselineDistance: Float
    let rerunBaselineDistance: Float?
    let maskedDistance: Float?
    let baselineConsistent: Bool
    let maskRequestFailed: Bool
    let wasProcessed: Bool

    var shadowDistance: Float {
        guard wasProcessed, baselineConsistent, let maskedDistance else {
            return baselineDistance
        }
        return maskedDistance
    }

    var appliedMask: Bool {
        wasProcessed && baselineConsistent && maskedDistance != nil
    }
}

struct ForegroundReserveRerankSummary: Sendable, Codable, Equatable {
    let reserveCount: Int
    let processedCount: Int
    let maskAppliedCount: Int
    let maskRequestFailureCount: Int
    let baselineConsistencyFailureCount: Int
    let frameEvaluationFailureCount: Int

    let detailBudget: Int
    let knownPositiveCount: Int
    let knownPositiveInReserveCount: Int
    let baselineWithinBudgetCount: Int
    let shadowWithinBudgetCount: Int
    let enteredBudgetCount: Int
    let leftBudgetCount: Int
    let improvedRankCount: Int
    let worsenedRankCount: Int
    let unchangedRankCount: Int
    let averageRankImprovement: Double?

    let elapsedSeconds: Double?
    let wasThermallyLimited: Bool

    var scopeNote: String {
        "初回analysis reserve内の同じ候補時刻だけを使うshadow再順位です。productionが再取得フレームで選んだ同じ局所cropにforeground全体maskを掛け、mask不可・未処理・baseline再現不一致は元distanceへfallbackします。reserve外の粗フレーム、maskで別regionを選ぶ可能性、動画全体recallは評価しません。"
    }
}

enum ForegroundReserveRerankAnalyzer {
    static func baselineIsConsistent(
        stored: Float,
        rerun: Float
    ) -> Bool {
        guard stored.isFinite, rerun.isFinite else { return false }
        let tolerance = max(0.015, abs(stored) * 0.04)
        return abs(stored - rerun) <= tolerance
    }

    static func summarize(
        points: [ForegroundReserveRerankPoint],
        detailBudget: Int,
        detailRadius: TimeInterval,
        knownSegments: [CandidateBudgetKnownSegment],
        elapsedSeconds: Double?,
        wasThermallyLimited: Bool,
        frameEvaluationFailureCount: Int
    ) -> ForegroundReserveRerankSummary? {
        guard !points.isEmpty, detailBudget > 0 else { return nil }

        let baseline = points
            .map { CandidateBudgetPoint(time: $0.time, distance: $0.baselineDistance) }
            .sorted { lhs, rhs in
                if lhs.distance == rhs.distance { return lhs.time < rhs.time }
                return lhs.distance < rhs.distance
            }

        let shadow = points
            .map { CandidateBudgetPoint(time: $0.time, distance: $0.shadowDistance) }
            .sorted { lhs, rhs in
                if lhs.distance == rhs.distance { return lhs.time < rhs.time }
                return lhs.distance < rhs.distance
            }

        var knownInReserve = 0
        var baselineWithin = 0
        var shadowWithin = 0
        var entered = 0
        var left = 0
        var improved = 0
        var worsened = 0
        var unchanged = 0
        var rankImprovements: [Double] = []

        for segment in knownSegments {
            let baselineRank = CandidateBudgetAnalyzer.rankCoveringSegment(
                startTime: segment.startTime,
                endTime: segment.endTime,
                detailRadius: detailRadius,
                rankedCandidates: baseline
            )
            let shadowRank = CandidateBudgetAnalyzer.rankCoveringSegment(
                startTime: segment.startTime,
                endTime: segment.endTime,
                detailRadius: detailRadius,
                rankedCandidates: shadow
            )

            guard let baselineRank, let shadowRank else { continue }
            knownInReserve += 1
            let baselineInside = baselineRank <= detailBudget
            let shadowInside = shadowRank <= detailBudget
            if baselineInside { baselineWithin += 1 }
            if shadowInside { shadowWithin += 1 }
            if !baselineInside && shadowInside { entered += 1 }
            if baselineInside && !shadowInside { left += 1 }

            if shadowRank < baselineRank {
                improved += 1
            } else if shadowRank > baselineRank {
                worsened += 1
            } else {
                unchanged += 1
            }
            rankImprovements.append(Double(baselineRank - shadowRank))
        }

        let averageRankImprovement: Double?
        if rankImprovements.isEmpty {
            averageRankImprovement = nil
        } else {
            averageRankImprovement = rankImprovements.reduce(0, +) / Double(rankImprovements.count)
        }

        return ForegroundReserveRerankSummary(
            reserveCount: points.count,
            processedCount: points.filter(\.wasProcessed).count,
            maskAppliedCount: points.filter(\.appliedMask).count,
            maskRequestFailureCount: points.filter(\.maskRequestFailed).count,
            baselineConsistencyFailureCount: points.filter { $0.wasProcessed && !$0.baselineConsistent }.count,
            frameEvaluationFailureCount: max(0, frameEvaluationFailureCount),
            detailBudget: detailBudget,
            knownPositiveCount: knownSegments.count,
            knownPositiveInReserveCount: knownInReserve,
            baselineWithinBudgetCount: baselineWithin,
            shadowWithinBudgetCount: shadowWithin,
            enteredBudgetCount: entered,
            leftBudgetCount: left,
            improvedRankCount: improved,
            worsenedRankCount: worsened,
            unchangedRankCount: unchanged,
            averageRankImprovement: averageRankImprovement,
            elapsedSeconds: elapsedSeconds,
            wasThermallyLimited: wasThermallyLimited
        )
    }
}
