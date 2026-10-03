import Foundation

struct ScanPipelinePoint: Sendable, Equatable {
    let time: TimeInterval
    let distance: Float
}

struct ScanPipelineObservation: Sendable, Equatable {
    let time: TimeInterval
    let distance: Float
    let rejectedByNegative: Bool
    let isAcceptedHit: Bool
}

struct ScanPipelineTimeWindow: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
}

struct ScanPipelineSegmentPlan: Sendable, Equatable {
    let hitRange: Range<Int>
    let bestHitIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let hitCount: Int
    let trackingScore: Double
}

enum ScanPipelineCore {
    static func insertDistinct<T>(
        _ candidate: T,
        into list: inout [T],
        limit: Int,
        minimumSpacing: TimeInterval,
        time: (T) -> TimeInterval,
        distance: (T) -> Float
    ) {
        if let nearby = list.firstIndex(where: {
            abs(time($0) - time(candidate)) < minimumSpacing
        }) {
            guard distance(candidate) < distance(list[nearby]) else { return }
            list.remove(at: nearby)
        }

        if let position = list.firstIndex(where: {
            distance(candidate) < distance($0)
        }) {
            list.insert(candidate, at: position)
        } else {
            list.append(candidate)
        }

        let boundedLimit = max(1, limit)
        if list.count > boundedLimit {
            list.removeLast(list.count - boundedLimit)
        }
    }

    static func percentile(_ values: [Float], quantile: Double) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let q = min(1, max(0, quantile))
        let index = min(
            sorted.count - 1,
            Int((Double(sorted.count - 1) * q).rounded(.down))
        )
        return sorted[index]
    }

    static func detailThreshold(coarseThreshold: Float) -> Float {
        coarseThreshold + max(0.015, coarseThreshold * 0.08)
    }

    static func mergedDetailWindows(
        candidates: [ScanPipelinePoint],
        duration: TimeInterval,
        radius: TimeInterval
    ) -> [ScanPipelineTimeWindow] {
        let raw = candidates.map {
            ScanPipelineTimeWindow(
                start: max(0, $0.time - radius),
                end: min(duration, $0.time + radius)
            )
        }.sorted { $0.start < $1.start }

        guard var current = raw.first else { return [] }
        var merged: [ScanPipelineTimeWindow] = []

        for next in raw.dropFirst() {
            if next.start <= current.end + 0.5 {
                current.end = max(current.end, next.end)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    static func segmentPlans(
        hits: [ScanPipelinePoint],
        duration: TimeInterval,
        detailInterval: TimeInterval,
        observations: [ScanPipelineObservation] = [],
        hitThreshold: Float? = nil
    ) -> [ScanPipelineSegmentPlan] {
        guard !hits.isEmpty else { return [] }

        let toleratedMissSpan = max(0.90, detailInterval * 5.0)
        let edgePadding = max(0.40, detailInterval * 1.5)
        let sortedObservations = observations.sorted { $0.time < $1.time }

        var ranges: [Range<Int>] = []
        var groupStart = 0

        if hits.count > 1 {
            for index in 1..<hits.count {
                let gap = hits[index].time - hits[index - 1].time
                if gap > toleratedMissSpan,
                   !shouldBridgeTemporaryMiss(
                       hits: hits,
                       splitIndex: index,
                       observations: sortedObservations,
                       hitThreshold: hitThreshold,
                       detailInterval: detailInterval,
                       toleratedMissSpan: toleratedMissSpan
                   ) {
                    ranges.append(groupStart..<index)
                    groupStart = index
                }
            }
        }
        ranges.append(groupStart..<hits.count)

        return ranges.map { range in
            let firstIndex = range.lowerBound
            let lastIndex = range.upperBound - 1
            var bestIndex = firstIndex

            for index in range.dropFirst() {
                if hits[index].distance < hits[bestIndex].distance {
                    bestIndex = index
                }
            }

            let observedSpan = max(
                detailInterval,
                hits[lastIndex].time - hits[firstIndex].time + detailInterval
            )
            let expectedSamples = max(
                1,
                Int((observedSpan / detailInterval).rounded(.up))
            )
            let trackingScore = min(
                1.0,
                Double(range.count) / Double(expectedSamples)
            )

            return ScanPipelineSegmentPlan(
                hitRange: range,
                bestHitIndex: bestIndex,
                startTime: max(0, hits[firstIndex].time - edgePadding),
                endTime: min(duration, hits[lastIndex].time + edgePadding),
                hitCount: range.count,
                trackingScore: trackingScore
            )
        }
    }

    private static func shouldBridgeTemporaryMiss(
        hits: [ScanPipelinePoint],
        splitIndex: Int,
        observations: [ScanPipelineObservation],
        hitThreshold: Float?,
        detailInterval: TimeInterval,
        toleratedMissSpan: TimeInterval
    ) -> Bool {
        guard let hitThreshold,
              !observations.isEmpty,
              splitIndex > 0,
              splitIndex < hits.count else {
            return false
        }

        let leftHit = hits[splitIndex - 1]
        let rightHit = hits[splitIndex]
        let gap = rightHit.time - leftHit.time
        let maximumBridgeSpan = max(
            toleratedMissSpan,
            min(2.25, toleratedMissSpan + 1.0)
        )
        guard gap <= maximumBridgeSpan else { return false }

        // A bridge is allowed only when both sides already look like a real
        // continuous appearance. A single isolated hit on either side is not
        // enough evidence to join two appearances.
        let flankWindow = max(0.75, detailInterval * 4.0)
        let leftFlankHitCount = hits[..<splitIndex].reduce(into: 0) { count, hit in
            if hit.time >= leftHit.time - flankWindow {
                count += 1
            }
        }
        let rightFlankHitCount = hits[splitIndex...].reduce(into: 0) { count, hit in
            if hit.time <= rightHit.time + flankWindow {
                count += 1
            }
        }
        guard leftFlankHitCount >= 2, rightFlankHitCount >= 2 else {
            return false
        }

        let epsilon = max(0.001, detailInterval * 0.10)
        let interior = observations.filter {
            $0.time > leftHit.time + epsilon &&
            $0.time < rightHit.time - epsilon
        }
        guard !interior.isEmpty else { return false }

        // Do not bridge across a region that was mostly not sampled. This keeps
        // decode failures or missing evidence from being mistaken for continuity.
        let expectedInteriorSamples = max(
            1,
            Int((gap / detailInterval).rounded(.down)) - 1
        )
        let minimumObservedSamples = max(
            1,
            Int(ceil(Double(expectedInteriorSamples) * 0.60))
        )
        guard interior.count >= minimumObservedSamples else { return false }

        // Existing hard-negative decisions are a veto. We do not change their
        // semantics; segmentation only consumes the already-computed result.
        guard !interior.contains(where: { $0.rejectedByNegative }) else {
            return false
        }

        // A temporary miss must still retain near-threshold Feature Print
        // evidence. These samples do not become hits and do not change the
        // recognition threshold; they are bridge-only evidence.
        let bridgeEvidenceThreshold =
            hitThreshold + max(0.015, hitThreshold * 0.08)
        let supportiveSamples = interior.filter {
            !$0.isAcceptedHit &&
            !$0.rejectedByNegative &&
            $0.distance <= bridgeEvidenceThreshold
        }
        let minimumSupportiveSamples = max(
            1,
            Int(ceil(Double(interior.count) * 0.50))
        )
        guard supportiveSamples.count >= minimumSupportiveSamples else {
            return false
        }

        // Require evidence near the middle of the gap as well, so two strong
        // appearances separated by a genuinely absent middle are not merged
        // merely because the timestamps are close.
        let midpoint = (leftHit.time + rightHit.time) / 2.0
        let midpointWindow = max(0.35, detailInterval * 1.5)
        return supportiveSamples.contains {
            abs($0.time - midpoint) <= midpointWindow
        }
    }
