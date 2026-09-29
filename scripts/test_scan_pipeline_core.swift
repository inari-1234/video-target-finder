import Foundation

@main
enum ScanPipelineCoreTests {
    static func approx(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    static func main() {
        let percentileValues: [Float] = [0.50, 0.20, 0.80, 0.10]
        precondition(ScanPipelineCore.percentile(percentileValues, quantile: 0.25) == 0.10)
        precondition(ScanPipelineCore.percentile(percentileValues, quantile: 0.50) == 0.20)
        precondition(ScanPipelineCore.percentile([], quantile: 0.50) == nil)

        var distinct: [ScanPipelinePoint] = []
        ScanPipelineCore.insertDistinct(
            ScanPipelinePoint(time: 0.0, distance: 0.50),
            into: &distinct,
            limit: 2,
            minimumSpacing: 0.75,
            time: { $0.time },
            distance: { $0.distance }
        )
        ScanPipelineCore.insertDistinct(
            ScanPipelinePoint(time: 0.2, distance: 0.40),
            into: &distinct,
            limit: 2,
            minimumSpacing: 0.75,
            time: { $0.time },
            distance: { $0.distance }
        )
        ScanPipelineCore.insertDistinct(
            ScanPipelinePoint(time: 2.0, distance: 0.30),
            into: &distinct,
            limit: 2,
            minimumSpacing: 0.75,
            time: { $0.time },
            distance: { $0.distance }
        )
        ScanPipelineCore.insertDistinct(
            ScanPipelinePoint(time: 4.0, distance: 0.60),
            into: &distinct,
            limit: 2,
            minimumSpacing: 0.75,
            time: { $0.time },
            distance: { $0.distance }
        )
        precondition(distinct.count == 2)
        precondition(distinct[0] == ScanPipelinePoint(time: 2.0, distance: 0.30))
        precondition(distinct[1] == ScanPipelinePoint(time: 0.2, distance: 0.40))

        // A worse nearby candidate must not replace the retained representative.
        let beforeWorseNearby = distinct
        ScanPipelineCore.insertDistinct(
            ScanPipelinePoint(time: 2.3, distance: 0.90),
            into: &distinct,
            limit: 2,
            minimumSpacing: 0.75,
            time: { $0.time },
            distance: { $0.distance }
        )
        precondition(distinct == beforeWorseNearby)

        // limit <= 0 is intentionally normalized to one retained candidate.
        var bounded: [ScanPipelinePoint] = []
        ScanPipelineCore.insertDistinct(
            ScanPipelinePoint(time: 1.0, distance: 0.50),
            into: &bounded,
            limit: 0,
            minimumSpacing: 0.25,
            time: { $0.time },
            distance: { $0.distance }
        )
        ScanPipelineCore.insertDistinct(
            ScanPipelinePoint(time: 3.0, distance: 0.20),
            into: &bounded,
            limit: 0,
            minimumSpacing: 0.25,
            time: { $0.time },
            distance: { $0.distance }
        )
        precondition(bounded == [ScanPipelinePoint(time: 3.0, distance: 0.20)])

        // Quantile clamps preserve current production behavior.
        precondition(ScanPipelineCore.percentile(percentileValues, quantile: -1.0) == 0.10)
        precondition(ScanPipelineCore.percentile(percentileValues, quantile: 2.0) == 0.80)

        let windows = ScanPipelineCore.mergedDetailWindows(
            candidates: [
                ScanPipelinePoint(time: 2.0, distance: 0.20),
                ScanPipelinePoint(time: 6.0, distance: 0.30),
                ScanPipelinePoint(time: 12.0, distance: 0.40)
            ],
            duration: 20.0,
            radius: 2.0
        )
        precondition(windows.count == 2)
        precondition(windows[0] == ScanPipelineTimeWindow(start: 0.0, end: 8.0))
        precondition(windows[1] == ScanPipelineTimeWindow(start: 10.0, end: 14.0))

        // Exactly 0.5 s between raw windows still merges; just above it splits.
        let boundaryMerge = ScanPipelineCore.mergedDetailWindows(
            candidates: [
                ScanPipelinePoint(time: 2.0, distance: 0.20),
                ScanPipelinePoint(time: 6.5, distance: 0.30)
            ],
            duration: 12.0,
            radius: 2.0
        )
        precondition(boundaryMerge == [ScanPipelineTimeWindow(start: 0.0, end: 8.5)])

        let boundarySplit = ScanPipelineCore.mergedDetailWindows(
            candidates: [
                ScanPipelinePoint(time: 2.0, distance: 0.20),
                ScanPipelinePoint(time: 6.5001, distance: 0.30)
            ],
            duration: 12.0,
            radius: 2.0
        )
        precondition(boundarySplit.count == 2)

        precondition(approx(Double(ScanPipelineCore.detailThreshold(coarseThreshold: 0.10)), 0.115))
        precondition(approx(Double(ScanPipelineCore.detailThreshold(coarseThreshold: 0.50)), 0.54))

        let plans = ScanPipelineCore.segmentPlans(
            hits: [
                ScanPipelinePoint(time: 1.00, distance: 0.40),
                ScanPipelinePoint(time: 1.25, distance: 0.20),
                ScanPipelinePoint(time: 2.00, distance: 0.30),
                ScanPipelinePoint(time: 4.00, distance: 0.10)
            ],
            duration: 10.0,
            detailInterval: 0.25
        )
        precondition(plans.count == 2)
        precondition(plans[0].hitRange == 0..<3)
        precondition(plans[0].bestHitIndex == 1)
        precondition(approx(plans[0].startTime, 0.60))
        precondition(approx(plans[0].endTime, 2.40))
        precondition(plans[0].hitCount == 3)
        precondition(approx(plans[0].trackingScore, 0.60))
        precondition(plans[1].hitRange == 3..<4)
        precondition(plans[1].bestHitIndex == 3)
        precondition(approx(plans[1].trackingScore, 1.0))

        // With detailInterval 0.25, tolerated gap is exactly 1.25 s.
        let exactTolerance = ScanPipelineCore.segmentPlans(
            hits: [
                ScanPipelinePoint(time: 1.00, distance: 0.30),
                ScanPipelinePoint(time: 2.25, distance: 0.20)
            ],
            duration: 5.0,
            detailInterval: 0.25
        )
        precondition(exactTolerance.count == 1)

        let beyondTolerance = ScanPipelineCore.segmentPlans(
            hits: [
                ScanPipelinePoint(time: 1.00, distance: 0.30),
                ScanPipelinePoint(time: 2.2501, distance: 0.20)
            ],
            duration: 5.0,
            detailInterval: 0.25
        )
        precondition(beyondTolerance.count == 2)

        print("ScanPipelineCore boundary cases: PASS")
        print("ScanPipelineCore tests: PASS")
    }
}
