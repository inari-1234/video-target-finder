import Foundation

@main
enum MaskingDiagnosticsTests {
    static func approx(_ lhs: Float?, _ rhs: Float, tolerance: Float = 0.0001) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= tolerance
    }

    static func result(
        all: Float?,
        single: Float?,
        failed: Bool = false
    ) -> MaskStrategyCandidateResult {
        MaskStrategyCandidateResult(
            allInstancesDistance: all,
            bestSingleDistance: single,
            instanceCount: all == nil && single == nil ? 0 : 2,
            evaluatedSingleCount: single == nil ? 0 : 2,
            requestFailed: failed
        )
    }

    static func main() {
        let samples = [
            MaskingLabeledSample(
                isConfirmed: true,
                scores: CandidateMaskDiagnosticScores(
                    baselineDistance: 0.50,
                    foreground: result(all: 0.40, single: 0.35),
                    person: result(all: 0.42, single: 0.38)
                )
            ),
            MaskingLabeledSample(
                isConfirmed: true,
                scores: CandidateMaskDiagnosticScores(
                    baselineDistance: 0.52,
                    foreground: result(all: 0.41, single: 0.36),
                    person: result(all: nil, single: nil)
                )
            ),
            MaskingLabeledSample(
                isConfirmed: false,
                scores: CandidateMaskDiagnosticScores(
                    baselineDistance: 0.54,
                    foreground: result(all: 0.60, single: 0.66),
                    person: result(all: 0.58, single: 0.63)
                )
            )
        ]

        guard let benchmark = MaskingDiagnosticAnalyzer.benchmark(
            samples: samples,
            diagnosticElapsedSeconds: 4.5,
            wasThermallyLimited: false
        ) else {
            fatalError("benchmark missing")
        }

        precondition(benchmark.attemptedReviewedCount == 3)
        precondition(benchmark.foregroundUnion.availableSampleCount == 3)
        precondition(benchmark.personBestSingle.availableSampleCount == 2)
        precondition(approx(benchmark.foregroundUnion.baseline.confirmedMean, 0.51))
        precondition(approx(benchmark.foregroundUnion.masked.confirmedMean, 0.405))
        precondition((benchmark.foregroundUnion.meanGapDelta ?? 0) > 0)
        precondition((benchmark.foregroundBestSingle.meanGapDelta ?? 0) > 0)
        precondition(benchmark.personBestSingle.confirmedCount == 1)
        precondition(benchmark.personBestSingle.rejectedCount == 1)
        precondition(benchmark.foregroundSingleTruncatedCandidateCount == 0)
        precondition(benchmark.personSingleTruncatedCandidateCount == 0)
        precondition(benchmark.diagnosticElapsedSeconds == 4.5)
        precondition(benchmark.wasThermallyLimited == false)

        let failed = MaskingLabeledSample(
            isConfirmed: false,
            scores: CandidateMaskDiagnosticScores(
                baselineDistance: 0.6,
                foreground: result(all: nil, single: nil, failed: true),
                person: result(all: nil, single: nil, failed: true)
            )
        )
        let failedBenchmark = MaskingDiagnosticAnalyzer.benchmark(
            samples: [failed],
            diagnosticElapsedSeconds: nil,
            wasThermallyLimited: true
        )
        precondition(failedBenchmark?.foregroundRequestFailureCount == 1)
        precondition(failedBenchmark?.personRequestFailureCount == 1)
        precondition(failedBenchmark?.wasThermallyLimited == true)

        print("MaskingDiagnostics tests: PASS")
    }
}
