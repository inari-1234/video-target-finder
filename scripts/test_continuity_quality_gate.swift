import Foundation

@main
struct ContinuityQualityGateTests {
    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func near(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 0.0001) -> Bool {
            abs(lhs - rhs) <= tolerance
        }

        let truth = [
            ContinuityGroundTruthAppearance(id: "A", startTime: 10, endTime: 20),
            ContinuityGroundTruthAppearance(id: "B", startTime: 30, endTime: 35)
        ]

        let fragmented = ContinuityQualityGateAnalyzer.evaluate(
            groundTruth: truth,
            detected: [
                ContinuityDetectedRange(startTime: 10, endTime: 14),
                ContinuityDetectedRange(startTime: 15, endTime: 20),
                ContinuityDetectedRange(startTime: 30, endTime: 35)
            ]
        )
        expect(fragmented.detectedAppearanceCount == 2, "both appearances should be detected")
        expect(near(fragmented.appearanceDetectionRate, 1), "appearance detection rate should be 100%")
        expect(near(fragmented.timeCoverageRate, 14.0 / 15.0), "time coverage should expose one-second miss")
        expect(near(fragmented.falsePositiveDuration, 0), "fragmented baseline should have no false-positive time")
        expect(fragmented.fragmentsPerAppearance["A"] == 2, "appearance A should have two fragments")
        expect(fragmented.fragmentsPerAppearance["B"] == 1, "appearance B should have one fragment")
        expect(fragmented.falseMergeCount == 0, "fragmented baseline should not false-merge appearances")

        let corrected = ContinuityQualityGateAnalyzer.evaluate(
            groundTruth: truth,
            detected: [
                ContinuityDetectedRange(startTime: 10, endTime: 20),
                ContinuityDetectedRange(startTime: 30, endTime: 35)
            ]
        )
        expect(near(corrected.timeCoverageRate, 1), "corrected output should cover all labeled time")
        expect(corrected.fragmentsPerAppearance["A"] == 1, "corrective should reduce A to one fragment")
        expect(near(corrected.falsePositiveDuration, 0), "corrective must not add false-positive time")
        expect(corrected.falseMergeCount == 0, "corrective must preserve true split")

        let falselyMerged = ContinuityQualityGateAnalyzer.evaluate(
            groundTruth: truth,
            detected: [ContinuityDetectedRange(startTime: 10, endTime: 35)]
        )
        expect(falselyMerged.falseMergeCount == 1, "one range spanning two appearances must be a false merge")
        expect(near(falselyMerged.falsePositiveDuration, 10), "gap between true appearances must count as false-positive time")

        if failures.isEmpty {
            print("Continuity quality gate tests: PASS")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
