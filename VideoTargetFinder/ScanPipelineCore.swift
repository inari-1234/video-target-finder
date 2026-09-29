import Foundation

struct ScanPipelinePoint: Sendable, Equatable {
    let time: TimeInterval
    let distance: Float
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
        detailInterval: TimeInterval
    ) -> [ScanPipelineSegmentPlan] {
        guard !hits.isEmpty else { return [] }

        let toleratedMissSpan = max(0.90, detailInterval * 5.0)
        let edgePadding = max(0.40, detailInterval * 1.5)

        var ranges: [Range<Int>] = []
        var groupStart = 0

        if hits.count > 1 {
            for index in 1..<hits.count {
                if hits[index].time - hits[index - 1].time > toleratedMissSpan {
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
}
