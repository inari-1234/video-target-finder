import CoreGraphics
import Foundation

struct InstanceMaskLabelGrid: Sendable, Equatable {
    let width: Int
    let height: Int
    let labels: [UInt16]

    init(width: Int, height: Int, labels: [UInt16]) {
        self.width = width
        self.height = height
        self.labels = labels
    }
}

struct InstanceTightBox: Sendable, Equatable {
    let instanceIndex: Int
    /// Mask画像内。左上原点、0...1。
    let localTopLeftRect: CGRect
    let pixelCount: Int
    let touchesMaskEdge: Bool
}

struct TrackingSeedFrameSample: Sendable, Equatable {
    let offsetSeconds: Double
    /// 動画フレーム全体。Vision形式（左下原点、0...1）。
    let visionRect: CGRect?
    let featureDistance: Float?
    let touchesSearchCropEdge: Bool
}

struct TrackingSeedCandidateDiagnostic: Sendable, Equatable {
    let segmentID: UUID
    let searchRegionArea: Double
    let samples: [TrackingSeedFrameSample]
}

struct TrackingSeedQualitySummary: Sendable, Codable, Equatable {
    let candidateCount: Int
    let centerSeedAvailableCount: Int
    let threeFrameAvailableCount: Int
    let centerEdgeTouchCount: Int

    let meanSeedToSearchAreaRatio: Double?
    let meanAdjacentIoU: Double?
    let meanAdjacentCenterShift: Double?
    let meanAreaSpreadRatio: Double?
    let stableSequenceCount: Int

    let elapsedSeconds: Double?
    let wasThermallyLimited: Bool
    let unsupportedMaskFormatCount: Int
    let frameFailureCount: Int

    var scopeNote: String {
        "正解判定済みの初回候補から最大8区間を使い、代表時刻±0.25秒で同じ検索regionを切り出してforeground instanceを再評価したtracking seed診断です。各時刻ではFeature Print距離が最小のforeground instanceを独立に選ぶため、隣接時刻で別の似た対象へ切り替わった場合も不安定として現れます。実際のVNTrackObjectRequest精度はまだ測定していません。"
    }
}

enum TrackingSeedBoxAnalyzer {
    static func tightBoxes(
        grid: InstanceMaskLabelGrid,
        instances: IndexSet
    ) -> [InstanceTightBox] {
        guard grid.width > 0,
              grid.height > 0,
              grid.labels.count == grid.width * grid.height,
              !instances.isEmpty else {
            return []
        }

        struct Accumulator {
            var minX: Int
            var minY: Int
            var maxX: Int
            var maxY: Int
            var count: Int
        }

        let allowed = Set(instances)
        var acc: [Int: Accumulator] = [:]

        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let label = Int(grid.labels[y * grid.width + x])
                guard label != 0, allowed.contains(label) else { continue }
                if var current = acc[label] {
                    current.minX = min(current.minX, x)
                    current.minY = min(current.minY, y)
                    current.maxX = max(current.maxX, x)
                    current.maxY = max(current.maxY, y)
                    current.count += 1
                    acc[label] = current
                } else {
                    acc[label] = Accumulator(
                        minX: x, minY: y, maxX: x, maxY: y, count: 1
                    )
                }
            }
        }

        return acc.keys.sorted().compactMap { index in
            guard let box = acc[index], box.count > 0 else { return nil }
            let minX = Double(box.minX) / Double(grid.width)
            let minY = Double(box.minY) / Double(grid.height)
            let maxX = Double(box.maxX + 1) / Double(grid.width)
            let maxY = Double(box.maxY + 1) / Double(grid.height)
            let rect = CGRect(
                x: minX,
                y: minY,
                width: max(0, maxX - minX),
                height: max(0, maxY - minY)
            )
            let touchesEdge =
                box.minX == 0 || box.minY == 0 ||
                box.maxX == grid.width - 1 || box.maxY == grid.height - 1
            return InstanceTightBox(
                instanceIndex: index,
                localTopLeftRect: rect,
                pixelCount: box.count,
                touchesMaskEdge: touchesEdge
            )
        }
    }

    static func mapLocalTopLeftRectToVision(
        _ local: CGRect,
        searchRegionTopLeft: CGRect
    ) -> CGRect? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let region = searchRegionTopLeft.intersection(unit)
        let localRect = local.intersection(unit)
        guard !region.isNull, !localRect.isNull,
              region.width > 0, region.height > 0,
              localRect.width > 0, localRect.height > 0 else {
            return nil
        }

        let fullTopLeft = CGRect(
            x: region.minX + localRect.minX * region.width,
            y: region.minY + localRect.minY * region.height,
            width: localRect.width * region.width,
            height: localRect.height * region.height
        ).intersection(unit)

        guard !fullTopLeft.isNull,
              fullTopLeft.width > 0, fullTopLeft.height > 0 else {
            return nil
        }

        // VisionのboundingBoxは左下原点。
        return CGRect(
            x: fullTopLeft.minX,
            y: 1 - fullTopLeft.maxY,
            width: fullTopLeft.width,
            height: fullTopLeft.height
        )
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let a = lhs.standardized
        let b = rhs.standardized
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return 0 }
        let intersection = a.intersection(b)
        let intersectionArea = intersection.isNull ? 0 : Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height + b.width * b.height) - intersectionArea
        guard union > 0 else { return 0 }
        return max(0, min(1, intersectionArea / union))
    }

    static func centerShift(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let dx = Double(lhs.midX - rhs.midX)
        let dy = Double(lhs.midY - rhs.midY)
        return hypot(dx, dy)
    }

    static func summarize(
        candidates: [TrackingSeedCandidateDiagnostic],
        elapsedSeconds: Double?,
        wasThermallyLimited: Bool,
        unsupportedMaskFormatCount: Int,
        frameFailureCount: Int
    ) -> TrackingSeedQualitySummary? {
        guard !candidates.isEmpty else { return nil }

        var centerAvailable = 0
        var threeAvailable = 0
        var edgeTouches = 0
        var areaRatios: [Double] = []
        var adjacentIoUs: [Double] = []
        var adjacentShifts: [Double] = []
        var areaSpreads: [Double] = []
        var stableSequences = 0

        for candidate in candidates {
            let sorted = candidate.samples.sorted { $0.offsetSeconds < $1.offsetSeconds }
            guard let center = sorted.min(by: { abs($0.offsetSeconds) < abs($1.offsetSeconds) }),
                  abs(center.offsetSeconds) < 0.001,
                  let centerRect = center.visionRect else {
                continue
            }

            centerAvailable += 1
            if center.touchesSearchCropEdge { edgeTouches += 1 }
            let seedArea = Double(centerRect.width * centerRect.height)
            if candidate.searchRegionArea > 0 {
                areaRatios.append(seedArea / candidate.searchRegionArea)
            }

            guard let before = sorted.first(where: { $0.offsetSeconds <= -0.15 && $0.visionRect != nil }),
                  let after = sorted.last(where: { $0.offsetSeconds >= 0.15 && $0.visionRect != nil }),
                  let beforeRect = before.visionRect,
                  let afterRect = after.visionRect else {
                continue
            }
            threeAvailable += 1
            let usable = [beforeRect, centerRect, afterRect]

            let iou1 = intersectionOverUnion(usable[0], usable[1])
            let iou2 = intersectionOverUnion(usable[1], usable[2])
            adjacentIoUs.append(contentsOf: [iou1, iou2])

            let shift1 = centerShift(usable[0], usable[1])
            let shift2 = centerShift(usable[1], usable[2])
            adjacentShifts.append(contentsOf: [shift1, shift2])

            let areas = usable.map { Double($0.width * $0.height) }.filter { $0 > 0 }
            let spread: Double
            if let minArea = areas.min(), let maxArea = areas.max(), minArea > 0 {
                spread = maxArea / minArea
                areaSpreads.append(spread)
            } else {
                spread = .infinity
            }

            // tracking投入前の診断用ヒューリスティック。実tracking成功率ではない。
            if min(iou1, iou2) >= 0.25,
               max(shift1, shift2) <= 0.20,
               spread <= 3.0 {
                stableSequences += 1
            }
        }

        return TrackingSeedQualitySummary(
            candidateCount: candidates.count,
            centerSeedAvailableCount: centerAvailable,
            threeFrameAvailableCount: threeAvailable,
            centerEdgeTouchCount: edgeTouches,
            meanSeedToSearchAreaRatio: average(areaRatios),
            meanAdjacentIoU: average(adjacentIoUs),
            meanAdjacentCenterShift: average(adjacentShifts),
            meanAreaSpreadRatio: average(areaSpreads),
            stableSequenceCount: stableSequences,
            elapsedSeconds: elapsedSeconds,
            wasThermallyLimited: wasThermallyLimited,
            unsupportedMaskFormatCount: max(0, unsupportedMaskFormatCount),
            frameFailureCount: max(0, frameFailureCount)
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
