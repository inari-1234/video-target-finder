import Foundation

@main
enum ReferenceScoreAnalyzerTests {
    static func approx(_ lhs: Float, _ rhs: Float, _ tolerance: Float = 0.00001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        guard let odd = ReferenceScoreAnalyzer.summarize(sourceDistances: [0.80, 0.20, 0.40]) else {
            fatalError("odd summary missing")
        }
        require(odd.sourceCount == 3, "source count")
        require(approx(odd.nearest, 0.20), "nearest")
        require(approx(odd.top2Mean, 0.30), "top2 mean")
        require(approx(odd.median, 0.40), "odd median")

        guard let even = ReferenceScoreAnalyzer.summarize(sourceDistances: [0.90, 0.10, 0.50, 0.30]) else {
            fatalError("even summary missing")
        }
        require(approx(even.median, 0.40), "even median")

        guard let across = ReferenceScoreAnalyzer.bestAcrossSamples([
            ReferenceAggregationScores(sourceCount: 3, nearest: 0.30, top2Mean: 0.50, median: 0.60),
            ReferenceAggregationScores(sourceCount: 3, nearest: 0.35, top2Mean: 0.40, median: 0.55)
        ]) else {
            fatalError("cross-sample summary missing")
        }
        require(approx(across.nearest, 0.30), "cross-sample nearest")
        require(approx(across.top2Mean, 0.40), "cross-sample top2 independent best")
        require(approx(across.median, 0.55), "cross-sample median independent best")

        let separated = ReferenceScoreAnalyzer.separation(
            confirmed: [0.20, 0.30],
            rejected: [0.50, 0.60]
        )
        require(approx(separated.confirmedMean ?? -1, 0.25), "positive mean")
        require(approx(separated.rejectedMean ?? -1, 0.55), "negative mean")
        require(approx(separated.meanGap ?? -1, 0.30), "mean gap")
        require(separated.overlaps == false, "non-overlap")

        let overlapping = ReferenceScoreAnalyzer.separation(
            confirmed: [0.20, 0.55],
            rejected: [0.50, 0.70]
        )
        require(overlapping.overlaps == true, "overlap")

        let samples = [
            ReferenceAggregationLabeledSample(
                isConfirmed: true,
                scores: ReferenceAggregationScores(
                    sourceCount: 3,
                    nearest: 0.20,
                    top2Mean: 0.32,
                    median: 0.42
                )
            ),
            ReferenceAggregationLabeledSample(
                isConfirmed: false,
                scores: ReferenceAggregationScores(
                    sourceCount: 3,
                    nearest: 0.24,
                    top2Mean: 0.48,
                    median: 0.62
                )
            )
        ]
        guard let benchmark = ReferenceScoreAnalyzer.benchmark(samples: samples) else {
            fatalError("benchmark missing")
        }
        require(benchmark.sampleCount == 2, "benchmark sample count")
        require(benchmark.confirmedCount == 1 && benchmark.rejectedCount == 1, "benchmark labels")
        require(
            (benchmark.top2Mean.meanGap ?? 0) > (benchmark.nearest.meanGap ?? 0),
            "top2 can show wider separation"
        )
        require(
            ReferenceScoreAnalyzer.summarize(sourceDistances: []) == nil,
            "empty distances"
        )

        print("ReferenceScoreAnalyzer tests: PASS")
    }
}
