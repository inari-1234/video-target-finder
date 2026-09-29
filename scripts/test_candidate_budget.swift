import Foundation

@main
struct CandidateBudgetAnalyzerTests {
    static func main() {
        let ranked = [
            CandidateBudgetPoint(time: 10, distance: 0.10),
            CandidateBudgetPoint(time: 50, distance: 0.20),
            CandidateBudgetPoint(time: 90, distance: 0.30),
            CandidateBudgetPoint(time: 130, distance: 0.40)
        ]

        let withinRank = CandidateBudgetAnalyzer.rankCoveringSegment(
            startTime: 47,
            endTime: 48,
            detailRadius: 4,
            rankedCandidates: ranked
        )
        precondition(withinRank == 2)
        precondition(
            CandidateBudgetAnalyzer.attribution(
                rank: withinRank,
                initialDetailBudget: 2
            ) == .withinInitialBudget
        )

        let outsideRank = CandidateBudgetAnalyzer.rankCoveringSegment(
            startTime: 126,
            endTime: 127,
            detailRadius: 4,
            rankedCandidates: ranked
        )
        precondition(outsideRank == 4)
        precondition(
            CandidateBudgetAnalyzer.attribution(
                rank: outsideRank,
                initialDetailBudget: 2
            ) == .outsideInitialBudget
        )

        let missingRank = CandidateBudgetAnalyzer.rankCoveringSegment(
            startTime: 200,
            endTime: 202,
            detailRadius: 4,
            rankedCandidates: ranked
        )
        precondition(missingRank == nil)
        precondition(
            CandidateBudgetAnalyzer.attribution(
                rank: missingRank,
                initialDetailBudget: 2
            ) == .notInInitialReserve
        )

        var reserve: [CandidateBudgetPoint] = []
        CandidateBudgetAnalyzer.insertDistinct(
            CandidateBudgetPoint(time: 10, distance: 0.30),
            into: &reserve,
            limit: 3,
            minimumSpacing: 1.0
        )
        CandidateBudgetAnalyzer.insertDistinct(
            CandidateBudgetPoint(time: 20, distance: 0.20),
            into: &reserve,
            limit: 3,
            minimumSpacing: 1.0
        )
        CandidateBudgetAnalyzer.insertDistinct(
            CandidateBudgetPoint(time: 30, distance: 0.40),
            into: &reserve,
            limit: 3,
            minimumSpacing: 1.0
        )
        CandidateBudgetAnalyzer.insertDistinct(
            CandidateBudgetPoint(time: 40, distance: 0.10),
            into: &reserve,
            limit: 3,
            minimumSpacing: 1.0
        )
        precondition(reserve.map(\.time) == [40, 20, 10])

        CandidateBudgetAnalyzer.insertDistinct(
            CandidateBudgetPoint(time: 20.2, distance: 0.15),
            into: &reserve,
            limit: 3,
            minimumSpacing: 1.0
        )
        precondition(reserve.map(\.time) == [40, 20.2, 10])
        precondition(reserve.map(\.distance) == [0.10, 0.15, 0.30])

        let normalPrefix = [
            CandidateBudgetPoint(time: 40, distance: 0.10),
            CandidateBudgetPoint(time: 20.2, distance: 0.15)
        ]
        precondition(
            CandidateBudgetAnalyzer.prefixMatches(
                normalCandidates: normalPrefix,
                rankedReserve: reserve
            )
        )
        precondition(
            !CandidateBudgetAnalyzer.prefixMatches(
                normalCandidates: normalPrefix + [
                    CandidateBudgetPoint(time: 99, distance: 0.25),
                    CandidateBudgetPoint(time: 100, distance: 0.26)
                ],
                rankedReserve: reserve
            )
        )
        precondition(
            !CandidateBudgetAnalyzer.prefixMatches(
                normalCandidates: [
                    CandidateBudgetPoint(time: 40.1, distance: 0.10),
                    CandidateBudgetPoint(time: 20.2, distance: 0.15)
                ],
                rankedReserve: reserve
            )
        )

        let boundaryRank = CandidateBudgetAnalyzer.rankCoveringSegment(
            startTime: 54,
            endTime: 54,
            detailRadius: 4,
            rankedCandidates: ranked
        )
        precondition(boundaryRank == 2)

        let curve = CandidateBudgetAnalyzer.coverageCurve(
            ranks: [4, 5, nil],
            budgets: [5, 3, 4, 5]
        )
        precondition(curve.map(\.budget) == [3, 4, 5])
        precondition(curve.map(\.coveredCount) == [0, 1, 2])
        precondition(curve.allSatisfy { $0.totalConfirmedCount == 3 })

        let temporallyRanked = [
            CandidateBudgetPoint(time: 5, distance: 0.10),
            CandidateBudgetPoint(time: 10, distance: 0.11),
            CandidateBudgetPoint(time: 15, distance: 0.12),
            CandidateBudgetPoint(time: 35, distance: 0.20),
            CandidateBudgetPoint(time: 65, distance: 0.30),
            CandidateBudgetPoint(time: 95, distance: 0.40)
        ]
        let diverse = CandidateBudgetAnalyzer.timeDiverseSelection(
            rankedCandidates: temporallyRanked,
            budget: 3,
            duration: 120,
            binCount: 4
        )
        precondition(diverse.map(\.time) == [5, 35, 65])

        let diversity = CandidateBudgetAnalyzer.temporalDiversitySummary(
            rankedCandidates: temporallyRanked,
            budget: 3,
            duration: 120,
            detailRadius: 0.5,
            knownSegments: [
                CandidateBudgetKnownSegment(startTime: 34.5, endTime: 35.5),
                CandidateBudgetKnownSegment(startTime: 64.5, endTime: 65.5)
            ],
            binCount: 4
        )
        precondition(diversity?.globalOccupiedBinCount == 1)
        precondition(diversity?.timeDiverseOccupiedBinCount == 3)
        precondition(diversity?.globalCoveredCount == 0)
        precondition(diversity?.timeDiverseCoveredCount == 2)
        precondition(diversity?.coverageDelta == 2)

        print("CandidateBudgetAnalyzer tests: PASS")
    }
}
