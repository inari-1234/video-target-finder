@preconcurrency import Vision
import CoreGraphics
import Foundation

struct RegionMatch: Sendable {
    let distance: Float
    let referenceIndex: Int
    let regionLabel: String
    let regionNormalizedRect: CGRect
    /// 誤検出として学習した見本の方が明確に近い場合は true。
    let rejectedByNegative: Bool
    let negativeDistance: Float?
    /// 見本画像単位でvariantを集約したA/B診断値。本番判定には使わない。
    let aggregationScores: ReferenceAggregationScores
}

/// 複数の正解見本と、任意の誤検出見本を使って動画フレームを比較する。
///
/// Stage 14:
/// - 正解見本は「全体」「中央寄せ」「顔・上半身寄せ」の3種類のFeature Printを内部生成する。
///   参考画像に別キャラクターや背景が入り込んでも、対象そのものの特徴を拾いやすくする。
/// - 誤検出判定された局所画像を hard negative として利用し、正解より負例に近い候補を抑制する。
final class FeaturePrintMatcher: @unchecked Sendable {
    private struct PositiveReference {
        let observation: VNFeaturePrintObservation
        let sourceIndex: Int
    }

    private let positives: [PositiveReference]
    private let negatives: [VNFeaturePrintObservation]
    private let lock = NSLock()

    init(referenceImages: [CGImage], negativeImages: [CGImage] = []) throws {
        guard !referenceImages.isEmpty else { throw MatcherError.noReferenceImages }

        var positiveFeatures: [PositiveReference] = []
        for (index, image) in referenceImages.enumerated() {
            for variant in Self.referenceVariants(for: image) {
                positiveFeatures.append(
                    PositiveReference(
                        observation: try Self.makeFeaturePrint(for: variant),
                        sourceIndex: index
                    )
                )
            }
        }
        self.positives = positiveFeatures

        var negativeFeatures: [VNFeaturePrintObservation] = []
        for image in negativeImages {
            // 負例も中央寄せを含める。false positiveのキャラクター本体を背景より重く見るため。
            for variant in Self.referenceVariants(for: image, includeHeadFocus: false) {
                negativeFeatures.append(try Self.makeFeaturePrint(for: variant))
            }
        }
        self.negatives = negativeFeatures
    }

    /// フレーム全体＋探索モードに応じた局所領域の中から、最も正解見本らしい組み合わせを返す。
    func bestMatch(in image: CGImage, mode: SearchSensitivity) throws -> RegionMatch {
        var bestAccepted: RegionMatch?
        var bestRejected: RegionMatch?
        var acceptedAggregationSamples: [ReferenceAggregationScores] = []

        for region in FrameRegionSampler.regions(for: mode) {
            guard let crop = FrameRegionSampler.croppedImage(from: image, region: region) else { continue }
            let candidate = try Self.makeFeaturePrint(for: crop)

            var positiveDistance = Float.greatestFiniteMagnitude
            var positiveIndex = 0
            var perSourceDistance: [Int: Float] = [:]

            for reference in positives {
                let distance = try distance(reference.observation, candidate)
                if distance < positiveDistance {
                    positiveDistance = distance
                    positiveIndex = reference.sourceIndex
                }
                let previous = perSourceDistance[reference.sourceIndex] ?? .greatestFiniteMagnitude
                if distance < previous {
                    perSourceDistance[reference.sourceIndex] = distance
                }
            }

            guard let aggregationScores = ReferenceScoreAnalyzer.summarize(
                sourceDistances: perSourceDistance.keys.sorted().compactMap { perSourceDistance[$0] }
            ) else {
                continue
            }

            var negativeDistance: Float?
            if !negatives.isEmpty {
                var closest = Float.greatestFiniteMagnitude
                for reference in negatives {
                    let distance = try distance(reference, candidate)
                    if distance < closest { closest = distance }
                }
                negativeDistance = closest
            }

            // lower is more similar. ほぼ同点なら正解側を残し、負例が明確に近い時だけ除外する。
            let separation = max(0.004, positiveDistance * 0.015)
            let rejectedByNegative = negativeDistance.map { $0 + separation < positiveDistance } ?? false

            let match = RegionMatch(
                distance: positiveDistance,
                referenceIndex: positiveIndex,
                regionLabel: region.label,
                regionNormalizedRect: region.normalizedRect,
                rejectedByNegative: rejectedByNegative,
                negativeDistance: negativeDistance,
                aggregationScores: aggregationScores
            )

            if rejectedByNegative {
                if bestRejected == nil || positiveDistance < bestRejected!.distance {
                    bestRejected = match
                }
            } else {
                acceptedAggregationSamples.append(aggregationScores)
                if bestAccepted == nil || positiveDistance < bestAccepted!.distance {
                    bestAccepted = match
                }
            }
        }

        if let bestAccepted {
            let diagnosticScores = ReferenceScoreAnalyzer.bestAcrossSamples(acceptedAggregationSamples)
                ?? bestAccepted.aggregationScores
            return RegionMatch(
                distance: bestAccepted.distance,
                referenceIndex: bestAccepted.referenceIndex,
                regionLabel: bestAccepted.regionLabel,
                regionNormalizedRect: bestAccepted.regionNormalizedRect,
                rejectedByNegative: bestAccepted.rejectedByNegative,
                negativeDistance: bestAccepted.negativeDistance,
                aggregationScores: diagnosticScores
            )
        }
        if let bestRejected { return bestRejected }
        throw MatcherError.noFeaturePrint
    }

    /// mask A/B専用。探索regionやnegative判定を通さず、同一画像に対する最短の正例distanceだけを再計算する。
    /// 本番のbestMatchや候補採否には使用しない。
    func diagnosticPositiveDistance(for image: CGImage) throws -> Float {
        let candidate = try Self.makeFeaturePrint(for: image)
        var best = Float.greatestFiniteMagnitude
        for reference in positives {
            let value = try distance(reference.observation, candidate)
            if value < best { best = value }
        }
        guard best.isFinite, best < .greatestFiniteMagnitude else {
            throw MatcherError.noFeaturePrint
        }
        return best
    }

    private func distance(_ lhs: VNFeaturePrintObservation, _ rhs: VNFeaturePrintObservation) throws -> Float {
        try lock.withLock {
            var value: Float = 0
            try lhs.computeDistance(&value, to: rhs)
            return value
        }
    }

    private static func referenceVariants(for image: CGImage, includeHeadFocus: Bool = true) -> [CGImage] {
        var result: [CGImage] = [image]

        // 中央の対象を優先。縦動画の端に入った別キャラクターや舞台背景の影響を減らす。
        if let focused = FrameRegionSampler.croppedImage(
            from: image,
            normalizedRect: CGRect(x: 0.08, y: 0.02, width: 0.84, height: 0.86)
        ) {
            result.append(focused)
        }

        // 顔・上半身はキャラクター識別に効きやすい。全身/接写の両方を見本にできるようにする。
        if includeHeadFocus,
           let upper = FrameRegionSampler.croppedImage(
                from: image,
                normalizedRect: CGRect(x: 0.10, y: 0.00, width: 0.80, height: 0.62)
           ) {
            result.append(upper)
        }

        return result
    }

    private static func makeFeaturePrint(for image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw MatcherError.noFeaturePrint
        }
        return observation
    }

    enum MatcherError: LocalizedError {
        case noReferenceImages
        case noFeaturePrint

        var errorDescription: String? {
            switch self {
            case .noReferenceImages:
                return "見本画像がありません。"
            case .noFeaturePrint:
                return "画像の特徴量を生成できませんでした。"
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
