import Foundation

@main
enum ForegroundReserveRerankDiagnosticsTests {
    static func point(
        _ time: Double,
        baseline: Float,
        masked: Float?,
        consistent: Bool = true,
        failed: Bool = false,
        processed: Bool = true
    ) -> ForegroundReserveRerankPoint {
        ForegroundReserveRerankPoint(
            time: time,
            baselineDistance: baseline,
            rerunBaselineDistance: baseline,
            maskedDistance: masked,
            baselineConsistent: consistent,
            maskRequestFailed: failed,
            wasProcessed: processed
        )
    }

    static func main() {
        precondition(
            ForegroundReserveRerankAnalyzer.baselineIsConsistent(stored: 0.50, rerun: 0.51)
        )
        precondition(
            !ForegroundReserveRerankAnalyzer.baselineIsConsistent(stored: 0.50, rerun: 0.54)
        )

        // baseline上位2件はt=10,20。mask後はt=30が上位2へ入り、既知正解をbudget内へ押し上げる。
        let points = [
            point(10, baseline: 0.10, masked: 0.10),
            point(20, baseline: 0.20, masked: 0.40),
            point(30, baseline: 0.30, masked: 0.12),
            point(40, baseline: 0.40, masked: nil, failed: true),
            point(50, baseline: 0.50, masked: 0.01, consistent: false)
        ]
        let known = [
            CandidateBudgetKnownSegment(startTime: 29.5, endTime: 30.5),
            CandidateBudgetKnownSegment(startTime: 9.5, endTime: 10.5)
        ]

        guard let summary = ForegroundReserveRerankAnalyzer.summarize(
            points: points,
            detailBudget: 2,
            detailRadius: 0.2,
            knownSegments: known,
            elapsedSeconds: 3.0,
            wasThermallyLimited: false,
            frameEvaluationFailureCount: 1
        ) else {
            fatalError("summary missing")
        }

        precondition(summary.reserveCount == 5)
        precondition(summary.processedCount == 5)
        precondition(summary.maskAppliedCount == 3)
        precondition(summary.maskRequestFailureCount == 1)
        precondition(summary.baselineConsistencyFailureCount == 1)
        precondition(summary.frameEvaluationFailureCount == 1)
        precondition(summary.knownPositiveCount == 2)
        precondition(summary.knownPositiveInReserveCount == 2)
        precondition(summary.baselineWithinBudgetCount == 1)
        precondition(summary.shadowWithinBudgetCount == 2)
        precondition(summary.enteredBudgetCount == 1)
        precondition(summary.leftBudgetCount == 0)
        precondition(summary.improvedRankCount >= 1)
        precondition((summary.averageRankImprovement ?? 0) > 0)

        // 未処理/不一致はbaselineへfallbackし、異常なmasked値で順位を変えない。
        let fallbackPoints = [
            point(1, baseline: 0.1, masked: 0.9, processed: false),
            point(2, baseline: 0.2, masked: 0.01, consistent: false)
        ]
        let fallback = ForegroundReserveRerankAnalyzer.summarize(
            points: fallbackPoints,
            detailBudget: 1,
            detailRadius: 0.1,
            knownSegments: [CandidateBudgetKnownSegment(startTime: 0.9, endTime: 1.1)],
            elapsedSeconds: nil,
            wasThermallyLimited: true,
            frameEvaluationFailureCount: 0
        )
        precondition(fallback?.baselineWithinBudgetCount == 1)
        precondition(fallback?.shadowWithinBudgetCount == 1)
        precondition(fallback?.maskAppliedCount == 0)
        precondition(fallback?.wasThermallyLimited == true)

        print("ForegroundReserveRerankDiagnostics tests: PASS")
    }
}
