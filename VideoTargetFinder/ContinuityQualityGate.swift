import Foundation

struct ContinuityGroundTruthAppearance: Sendable, Equatable {
    let id: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct ContinuityDetectedRange: Sendable, Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct ContinuityQualityMetrics: Sendable, Equatable {
    let appearanceCount: Int
    let detectedAppearanceCount: Int
    let appearanceDetectionRate: Double
    let trueAppearanceDuration: TimeInterval
    let coveredAppearanceDuration: TimeInterval
    let timeCoverageRate: Double
    let falsePositiveDuration: TimeInterval
    let fragmentsPerAppearance: [String: Int]
    let falseMergeCount: Int

    var totalFragmentCount: Int {
        fragmentsPerAppearance.values.reduce(0, +)
    }

    func passesNonRegressionGate(against baseline: ContinuityQualityMetrics) -> Bool {
        let epsilon = 0.000_001
        return appearanceDetectionRate + epsilon >= baseline.appearanceDetectionRate &&
            timeCoverageRate + epsilon >= baseline.timeCoverageRate &&
            falsePositiveDuration <= baseline.falsePositiveDuration + epsilon &&
            totalFragmentCount <= baseline.totalFragmentCount &&
            falseMergeCount == 0
    }
}

enum ContinuityQualityGateAnalyzer {
    static func evaluate(
        groundTruth: [ContinuityGroundTruthAppearance],
        detected: [ContinuityDetectedRange]
    ) -> ContinuityQualityMetrics {
        let truth = groundTruth
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        let detections = detected
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }

        let detectedAppearanceCount = truth.reduce(into: 0) { count, appearance in
            if detections.contains(where: { overlap($0, appearance) > 0.000_001 }) {
                count += 1
            }
        }

        let truthUnion = union(truth.map { ($0.startTime, $0.endTime) })
        let detectionUnion = union(detections.map { ($0.startTime, $0.endTime) })
        let trueDuration = duration(of: truthUnion)
        let coveredDuration = intersectionDuration(lhs: truthUnion, rhs: detectionUnion)
        let detectionDuration = duration(of: detectionUnion)
        let falsePositiveDuration = max(0, detectionDuration - coveredDuration)

        var fragments: [String: Int] = [:]
        for appearance in truth {
            fragments[appearance.id] = detections.filter {
                overlap($0, appearance) > 0.000_001
            }.count
        }

        let falseMergeCount = detections.reduce(into: 0) { count, segment in
            let touched = truth.filter { overlap(segment, $0) > 0.000_001 }.count
            if touched > 1 { count += 1 }
        }

        return ContinuityQualityMetrics(
            appearanceCount: truth.count,
            detectedAppearanceCount: detectedAppearanceCount,
            appearanceDetectionRate: truth.isEmpty
                ? 1
                : Double(detectedAppearanceCount) / Double(truth.count),
            trueAppearanceDuration: trueDuration,
            coveredAppearanceDuration: coveredDuration,
            timeCoverageRate: trueDuration > 0 ? min(1, coveredDuration / trueDuration) : 1,
            falsePositiveDuration: falsePositiveDuration,
            fragmentsPerAppearance: fragments,
            falseMergeCount: falseMergeCount
        )
    }

    private static func overlap(
        _ detected: ContinuityDetectedRange,
        _ truth: ContinuityGroundTruthAppearance
    ) -> TimeInterval {
        max(0, min(detected.endTime, truth.endTime) - max(detected.startTime, truth.startTime))
    }

    private static func union(_ ranges: [(TimeInterval, TimeInterval)]) -> [(TimeInterval, TimeInterval)] {
        let sorted = ranges
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return [] }
        var result: [(TimeInterval, TimeInterval)] = []
        for next in sorted.dropFirst() {
            if next.0 <= current.1 {
                current.1 = max(current.1, next.1)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private static func duration(of ranges: [(TimeInterval, TimeInterval)]) -> TimeInterval {
        ranges.reduce(0) { $0 + max(0, $1.1 - $1.0) }
    }

    private static func intersectionDuration(
        lhs: [(TimeInterval, TimeInterval)],
        rhs: [(TimeInterval, TimeInterval)]
    ) -> TimeInterval {
        var i = 0
        var j = 0
        var total: TimeInterval = 0
        while i < lhs.count, j < rhs.count {
            let start = max(lhs[i].0, rhs[j].0)
            let end = min(lhs[i].1, rhs[j].1)
            if end > start { total += end - start }
            if lhs[i].1 < rhs[j].1 {
                i += 1
            } else {
                j += 1
            }
        }
        return total
    }
}
