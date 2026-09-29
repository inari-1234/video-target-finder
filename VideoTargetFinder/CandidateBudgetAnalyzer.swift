import Foundation

struct CandidateBudgetPoint: Sendable, Codable, Equatable {
    let time: TimeInterval
    let distance: Float
}

enum CandidateBudgetAttribution: String, Sendable, Codable {
    case withinInitialBudget
    case outsideInitialBudget
    case notInInitialReserve
}

struct CandidateBudgetCoveragePoint: Identifiable, Sendable, Codable, Equatable {
    let budget: Int
    let coveredCount: Int
    let totalConfirmedCount: Int

    var id: Int { budget }

    var coverageRatio: Double? {
        guard totalConfirmedCount > 0 else { return nil }
        return Double(coveredCount) / Double(totalConfirmedCount)
    }
}

struct CandidateTemporalDiversitySummary: Sendable, Codable, Equatable {
    let binCount: Int
    let budget: Int
    let knownPositiveCount: Int
    let globalCoveredCount: Int
    let timeDiverseCoveredCount: Int
    let globalOccupiedBinCount: Int
    let timeDiverseOccupiedBinCount: Int

    var coverageDelta: Int {
        timeDiverseCoveredCount - globalCoveredCount
    }
}

struct CandidateBudgetAnalysisSummary: Sendable, Codable {
    let initialDetailBudget: Int
    let initialReserveLimit: Int
    let initialReserveCount: Int
    let rescanConfirmedCount: Int
    let withinInitialBudgetCount: Int
    let outsideInitialBudgetCount: Int
    let notInInitialReserveCount: Int
    /// v0.22以降。旧保存レポートではnil。
    let coverageCurve: [CandidateBudgetCoveragePoint]?
    /// v0.22以降。旧保存レポートではnil。
    let temporalDiversity: CandidateTemporalDiversitySummary?

    var accountedCount: Int {
        withinInitialBudgetCount + outsideInitialBudgetCount + notInInitialReserveCount
    }

    var compactText: String {
        "初回予算内 \(withinInitialBudgetCount) / 予算外 \(outsideInitialBudgetCount) / 初回粗探索にも無し \(notInInitialReserveCount)"
    }
}

struct CandidateBudgetKnownSegment: Sendable, Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum CandidateBudgetAnalyzer {
    static func insertDistinct(
        _ point: CandidateBudgetPoint,
        into list: inout [CandidateBudgetPoint],
        limit: Int,
        minimumSpacing: TimeInterval
    ) {
        ScanPipelineCore.insertDistinct(
            point,
            into: &list,
            limit: limit,
            minimumSpacing: minimumSpacing,
            time: { $0.time },
            distance: { $0.distance }
        )
    }

    static func prefixMatches(
        normalCandidates: [CandidateBudgetPoint],
        rankedReserve: [CandidateBudgetPoint],
        timeTolerance: TimeInterval = 0.001,
        distanceTolerance: Float = 0.000_001
    ) -> Bool {
        guard rankedReserve.count >= normalCandidates.count else { return false }

        for (normal, reserve) in zip(
            normalCandidates,
            rankedReserve.prefix(normalCandidates.count)
        ) {
            if abs(normal.time - reserve.time) > max(0, timeTolerance) {
                return false
            }
            if abs(normal.distance - reserve.distance) > max(0, distanceTolerance) {
                return false
            }
        }
        return true
    }

    static func rankCoveringSegment(
        startTime: TimeInterval,
        endTime: TimeInterval,
        detailRadius: TimeInterval,
        rankedCandidates: [CandidateBudgetPoint]
    ) -> Int? {
        let lower = max(0, min(startTime, endTime) - max(0, detailRadius))
        let upper = max(startTime, endTime) + max(0, detailRadius)

        guard let index = rankedCandidates.firstIndex(where: {
            $0.time >= lower && $0.time <= upper
        }) else {
            return nil
        }
        return index + 1
    }

    static func attribution(
        rank: Int?,
        initialDetailBudget: Int
    ) -> CandidateBudgetAttribution {
        guard let rank else { return .notInInitialReserve }
        return rank <= max(0, initialDetailBudget)
            ? .withinInitialBudget
            : .outsideInitialBudget
    }

    /// 既知の再探索正解が、初回粗候補ランキングの上位K件で何件カバーされるかを見る。
    /// 詳細探索を実際に通過することを保証する指標ではない。
    static func coverageCurve(
        ranks: [Int?],
        budgets: [Int]
    ) -> [CandidateBudgetCoveragePoint] {
        let normalizedBudgets = Array(Set(budgets.filter { $0 > 0 })).sorted()
        return normalizedBudgets.map { budget in
            let covered = ranks.compactMap { $0 }.filter { $0 <= budget }.count
            return CandidateBudgetCoveragePoint(
                budget: budget,
                coveredCount: covered,
                totalConfirmedCount: ranks.count
            )
        }
    }

    /// global distance上位だけに偏らず、動画を等分した時間binから1件ずつ順番に拾う仮想選択。
    /// 本番候補には使わず、時間方向の集中が見逃し要因かを診断するためだけに使う。
    static func timeDiverseSelection(
        rankedCandidates: [CandidateBudgetPoint],
        budget: Int,
        duration: TimeInterval,
        binCount: Int
    ) -> [CandidateBudgetPoint] {
        let safeBudget = max(0, budget)
        let safeBins = max(1, binCount)
        guard safeBudget > 0, duration.isFinite, duration > 0 else { return [] }

        var bins = Array(repeating: [CandidateBudgetPoint](), count: safeBins)
        for point in rankedCandidates {
            let normalized = max(0, min(1, point.time / duration))
            let index = min(safeBins - 1, max(0, Int(normalized * Double(safeBins))))
            bins[index].append(point)
        }

        var selected: [CandidateBudgetPoint] = []
        var depth = 0
        while selected.count < safeBudget {
            let round = bins.compactMap { bin -> CandidateBudgetPoint? in
                guard depth < bin.count else { return nil }
                return bin[depth]
            }.sorted { lhs, rhs in
                if lhs.distance == rhs.distance { return lhs.time < rhs.time }
                return lhs.distance < rhs.distance
            }

            guard !round.isEmpty else { break }
            for point in round {
                selected.append(point)
                if selected.count == safeBudget { break }
            }
            depth += 1
        }
        return selected
    }

    static func occupiedBinCount(
        candidates: [CandidateBudgetPoint],
        duration: TimeInterval,
        binCount: Int
    ) -> Int {
        let safeBins = max(1, binCount)
        guard duration.isFinite, duration > 0 else { return 0 }
        let bins = Set(candidates.map { point -> Int in
            let normalized = max(0, min(1, point.time / duration))
            return min(safeBins - 1, max(0, Int(normalized * Double(safeBins))))
        })
        return bins.count
    }

    static func coveredSegmentCount(
        segments: [CandidateBudgetKnownSegment],
        detailRadius: TimeInterval,
        candidates: [CandidateBudgetPoint]
    ) -> Int {
        segments.filter { segment in
            rankCoveringSegment(
                startTime: segment.startTime,
                endTime: segment.endTime,
                detailRadius: detailRadius,
                rankedCandidates: candidates
            ) != nil
        }.count
    }

    static func temporalDiversitySummary(
        rankedCandidates: [CandidateBudgetPoint],
        budget: Int,
        duration: TimeInterval,
        detailRadius: TimeInterval,
        knownSegments: [CandidateBudgetKnownSegment],
        binCount: Int = 6
    ) -> CandidateTemporalDiversitySummary? {
        guard duration.isFinite, duration > 0, budget > 0 else { return nil }

        let global = Array(rankedCandidates.prefix(budget))
        let diverse = timeDiverseSelection(
            rankedCandidates: rankedCandidates,
            budget: budget,
            duration: duration,
            binCount: binCount
        )

        return CandidateTemporalDiversitySummary(
            binCount: max(1, binCount),
            budget: budget,
            knownPositiveCount: knownSegments.count,
            globalCoveredCount: coveredSegmentCount(
                segments: knownSegments,
                detailRadius: detailRadius,
                candidates: global
            ),
            timeDiverseCoveredCount: coveredSegmentCount(
                segments: knownSegments,
                detailRadius: detailRadius,
                candidates: diverse
            ),
            globalOccupiedBinCount: occupiedBinCount(
                candidates: global,
                duration: duration,
                binCount: binCount
            ),
            timeDiverseOccupiedBinCount: occupiedBinCount(
                candidates: diverse,
                duration: duration,
                binCount: binCount
            )
        )
    }
}
