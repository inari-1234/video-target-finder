import CoreGraphics
import Foundation

enum ObjectTrackingSeedVariant: String, Sendable, Codable, CaseIterable {
    case tight
    case padded

    var displayName: String {
        switch self {
        case .tight: return "mask tight box"
        case .padded: return "10% margin box"
        }
    }
}

enum ObjectTrackingDirection: String, Sendable, Codable {
    case forward
    case backward
}

struct ObjectTrackingFrameDiagnostic: Sendable, Equatable {
    let direction: ObjectTrackingDirection
    let offsetSeconds: Double
    let trackedRect: CGRect?
    let confidence: Float?
    /// 同じ時刻をforeground+Feature Printで独立再検出した参照box。ground truthではない。
    let referenceRect: CGRect?
}

struct ObjectTrackingVariantDiagnostic: Sendable, Equatable {
    let variant: ObjectTrackingSeedVariant
    let samples: [ObjectTrackingFrameDiagnostic]
}

struct ObjectTrackingCandidateDiagnostic: Sendable, Equatable {
    let segmentID: UUID
    let seedRect: CGRect
    let variants: [ObjectTrackingVariantDiagnostic]
}

struct ObjectTrackingVariantSummary: Sendable, Codable, Equatable {
    let variant: ObjectTrackingSeedVariant
    let attemptedFrameCount: Int
    let trackedFrameCount: Int
    let comparableFrameCount: Int
    let referenceAgreementFrameCount: Int
    let meanConfidence: Double?
    let meanReferenceIoU: Double?
    let meanReferenceCenterShift: Double?
    let directionLossCount: Int

    var continuationRate: Double? {
        guard attemptedFrameCount > 0 else { return nil }
        return Double(trackedFrameCount) / Double(attemptedFrameCount)
    }

    var referenceAgreementRate: Double? {
        guard comparableFrameCount > 0 else { return nil }
        return Double(referenceAgreementFrameCount) / Double(comparableFrameCount)
    }
}

struct ObjectTrackingBenchmarkSummary: Sendable, Codable, Equatable {
    let candidateCount: Int
    let seededCandidateCount: Int
    let tight: ObjectTrackingVariantSummary
    let padded: ObjectTrackingVariantSummary
    let elapsedSeconds: Double?
    let wasThermallyLimited: Bool
    let seedFailureCount: Int
    let referenceDetectionFailureCount: Int
    let frameLoadFailureCount: Int

    var scopeNote: String {
        "正解判定済み初回候補のうち最大4区間を対象に、中央foreground instance boxをseedとしてVNTrackObjectRequestを前後各1秒（0.125秒間隔）へ独立追跡した診断です。tracker boxは同時刻のforeground+Feature Print独立再検出boxと比較しますが、その参照boxもground truthではなく別の似た対象へ切り替わる可能性があります。本番の粗探索・詳細探索・候補採否には使用しません。"
    }
}

enum ObjectTrackingDiagnosticAnalyzer {
    static func paddedSeedRect(_ rect: CGRect, marginFraction: Double = 0.10) -> CGRect {
        let r = rect.standardized
        guard r.width > 0, r.height > 0 else { return .null }
        let dx = r.width * marginFraction
        let dy = r.height * marginFraction
        return CGRect(
            x: r.minX - dx,
            y: r.minY - dy,
            width: r.width + dx * 2,
            height: r.height + dy * 2
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func summarizeVariant(
        _ variant: ObjectTrackingSeedVariant,
        candidates: [ObjectTrackingCandidateDiagnostic]
    ) -> ObjectTrackingVariantSummary {
        let samples = candidates
            .flatMap(\.variants)
            .filter { $0.variant == variant }
            .flatMap(\.samples)

        let tracked = samples.filter { $0.trackedRect != nil }
        let comparable = samples.filter { $0.trackedRect != nil && $0.referenceRect != nil }
        let confidences = tracked.compactMap { $0.confidence.map(Double.init) }

        var ious: [Double] = []
        var shifts: [Double] = []
        var agreements = 0
        for sample in comparable {
            guard let trackedRect = sample.trackedRect,
                  let referenceRect = sample.referenceRect else { continue }
            let iou = TrackingSeedBoxAnalyzer.intersectionOverUnion(trackedRect, referenceRect)
            let shift = TrackingSeedBoxAnalyzer.centerShift(trackedRect, referenceRect)
            ious.append(iou)
            shifts.append(shift)
            if iou >= 0.20 && shift <= 0.20 {
                agreements += 1
            }
        }

        var directionLossCount = 0
        for candidate in candidates {
            guard let candidateVariant = candidate.variants.first(where: { $0.variant == variant }) else {
                continue
            }
            for direction in [ObjectTrackingDirection.forward, .backward] {
                let directionSamples = candidateVariant.samples
                    .filter { $0.direction == direction }
                    .sorted { abs($0.offsetSeconds) < abs($1.offsetSeconds) }
                if !directionSamples.isEmpty, directionSamples.contains(where: { $0.trackedRect == nil }) {
                    directionLossCount += 1
                }
            }
        }

        return ObjectTrackingVariantSummary(
            variant: variant,
            attemptedFrameCount: samples.count,
            trackedFrameCount: tracked.count,
            comparableFrameCount: comparable.count,
            referenceAgreementFrameCount: agreements,
            meanConfidence: average(confidences),
            meanReferenceIoU: average(ious),
            meanReferenceCenterShift: average(shifts),
            directionLossCount: directionLossCount
        )
    }

    static func benchmark(
        candidates: [ObjectTrackingCandidateDiagnostic],
        elapsedSeconds: Double?,
        wasThermallyLimited: Bool,
        seedFailureCount: Int,
        referenceDetectionFailureCount: Int,
        frameLoadFailureCount: Int
    ) -> ObjectTrackingBenchmarkSummary? {
        guard !candidates.isEmpty || seedFailureCount > 0 else { return nil }
        return ObjectTrackingBenchmarkSummary(
            candidateCount: candidates.count + max(0, seedFailureCount),
            seededCandidateCount: candidates.count,
            tight: summarizeVariant(.tight, candidates: candidates),
            padded: summarizeVariant(.padded, candidates: candidates),
            elapsedSeconds: elapsedSeconds,
            wasThermallyLimited: wasThermallyLimited,
            seedFailureCount: max(0, seedFailureCount),
            referenceDetectionFailureCount: max(0, referenceDetectionFailureCount),
            frameLoadFailureCount: max(0, frameLoadFailureCount)
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
