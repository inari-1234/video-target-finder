import CoreGraphics
import Foundation

enum SegmentVisualContinuityReason: String, Sendable, Equatable {
    case insufficientTrackingSamples = "insufficient-tracking-samples"
    case missingMidpointReference = "missing-midpoint-reference"
    case trackingLostOrFailed = "tracking-lost-or-failed"
    case insufficientTrackingConfidence = "insufficient-tracking-confidence"
    case trackersDisagree = "trackers-disagree"
    case forwardMissesMidpoint = "forward-misses-midpoint"
    case backwardMissesMidpoint = "backward-misses-midpoint"
    case invalidTrackedArea = "invalid-tracked-area"
    case areaRatioTooLarge = "area-ratio-too-large"
    case confirmed = "confirmed"
}

struct SegmentVisualContinuityDiagnostic: Sendable, Equatable {
    let shouldBridge: Bool
    let reason: SegmentVisualContinuityReason
    let forwardCount: Int
    let backwardCount: Int
    let minimumConfidence: Double?
    let meanConfidence: Double?
    let trackerIoU: Double?
    let trackerCenterShift: Double?
    let forwardMidpointIoU: Double?
    let forwardMidpointShift: Double?
    let backwardMidpointIoU: Double?
    let backwardMidpointShift: Double?
    let areaRatio: Double?
}

enum SegmentContinuityAnalyzer {
    static func shouldBridge(
        forward: [VisionTrackingFrameOutput],
        backward: [VisionTrackingFrameOutput],
        midpointReferenceRect: CGRect?
    ) -> Bool {
        let diagnostic = evaluate(
            forward: forward,
            backward: backward,
            midpointReferenceRect: midpointReferenceRect
        )
        emitDiagnostic(diagnostic)
        return diagnostic.shouldBridge
    }

    static func evaluate(
        forward: [VisionTrackingFrameOutput],
        backward: [VisionTrackingFrameOutput],
        midpointReferenceRect: CGRect?
    ) -> SegmentVisualContinuityDiagnostic {
        func result(
            _ shouldBridge: Bool,
            _ reason: SegmentVisualContinuityReason,
            minimumConfidence: Double? = nil,
            meanConfidence: Double? = nil,
            trackerIoU: Double? = nil,
            trackerCenterShift: Double? = nil,
            forwardMidpointIoU: Double? = nil,
            forwardMidpointShift: Double? = nil,
            backwardMidpointIoU: Double? = nil,
            backwardMidpointShift: Double? = nil,
            areaRatio: Double? = nil
        ) -> SegmentVisualContinuityDiagnostic {
            SegmentVisualContinuityDiagnostic(
                shouldBridge: shouldBridge,
                reason: reason,
                forwardCount: forward.count,
                backwardCount: backward.count,
                minimumConfidence: minimumConfidence,
                meanConfidence: meanConfidence,
                trackerIoU: trackerIoU,
                trackerCenterShift: trackerCenterShift,
                forwardMidpointIoU: forwardMidpointIoU,
                forwardMidpointShift: forwardMidpointShift,
                backwardMidpointIoU: backwardMidpointIoU,
                backwardMidpointShift: backwardMidpointShift,
                areaRatio: areaRatio
            )
        }

        guard forward.count >= 2, backward.count >= 2 else {
            return result(false, .insufficientTrackingSamples)
        }
        guard let midpointReferenceRect,
              !midpointReferenceRect.isNull,
              midpointReferenceRect.width > 0,
              midpointReferenceRect.height > 0 else {
            return result(false, .missingMidpointReference)
        }
        guard !forward.contains(where: { $0.requestFailed || $0.boundingBox == nil }),
              !backward.contains(where: { $0.requestFailed || $0.boundingBox == nil }),
              let forwardMidpoint = forward.last?.boundingBox,
              let backwardMidpoint = backward.last?.boundingBox else {
            return result(false, .trackingLostOrFailed)
        }

        let confidences = (forward + backward).compactMap(\.confidence).map(Double.init)
        let minimumConfidence = confidences.min()
        let meanConfidence = confidences.count == forward.count + backward.count
            ? average(confidences)
            : nil
        guard confidences.count == forward.count + backward.count,
              let minimumConfidence,
              let meanConfidence,
              minimumConfidence >= 0.25,
              meanConfidence >= 0.45 else {
            return result(
                false,
                .insufficientTrackingConfidence,
                minimumConfidence: minimumConfidence,
                meanConfidence: meanConfidence
            )
        }

        let trackerIoU = intersectionOverUnion(forwardMidpoint, backwardMidpoint)
        let trackerCenterShift = centerShift(forwardMidpoint, backwardMidpoint)
        guard trackerIoU >= 0.35 || trackerCenterShift <= 0.10 else {
            return result(
                false,
                .trackersDisagree,
                minimumConfidence: minimumConfidence,
                meanConfidence: meanConfidence,
                trackerIoU: trackerIoU,
                trackerCenterShift: trackerCenterShift
            )
        }

        let forwardMidpointIoU = intersectionOverUnion(forwardMidpoint, midpointReferenceRect)
        let forwardMidpointShift = centerShift(forwardMidpoint, midpointReferenceRect)
        guard forwardMidpointIoU >= 0.20 || forwardMidpointShift <= 0.15 else {
            return result(
                false,
                .forwardMissesMidpoint,
                minimumConfidence: minimumConfidence,
                meanConfidence: meanConfidence,
                trackerIoU: trackerIoU,
                trackerCenterShift: trackerCenterShift,
                forwardMidpointIoU: forwardMidpointIoU,
                forwardMidpointShift: forwardMidpointShift
            )
        }

        let backwardMidpointIoU = intersectionOverUnion(backwardMidpoint, midpointReferenceRect)
        let backwardMidpointShift = centerShift(backwardMidpoint, midpointReferenceRect)
        guard backwardMidpointIoU >= 0.20 || backwardMidpointShift <= 0.15 else {
            return result(
                false,
                .backwardMissesMidpoint,
                minimumConfidence: minimumConfidence,
                meanConfidence: meanConfidence,
                trackerIoU: trackerIoU,
                trackerCenterShift: trackerCenterShift,
                forwardMidpointIoU: forwardMidpointIoU,
                forwardMidpointShift: forwardMidpointShift,
                backwardMidpointIoU: backwardMidpointIoU,
                backwardMidpointShift: backwardMidpointShift
            )
        }

        let forwardArea = Double(forwardMidpoint.width * forwardMidpoint.height)
        let backwardArea = Double(backwardMidpoint.width * backwardMidpoint.height)
        guard forwardArea > 0, backwardArea > 0 else {
            return result(
                false,
                .invalidTrackedArea,
                minimumConfidence: minimumConfidence,
                meanConfidence: meanConfidence,
                trackerIoU: trackerIoU,
                trackerCenterShift: trackerCenterShift,
                forwardMidpointIoU: forwardMidpointIoU,
                forwardMidpointShift: forwardMidpointShift,
                backwardMidpointIoU: backwardMidpointIoU,
                backwardMidpointShift: backwardMidpointShift
            )
        }
        let areaRatio = max(forwardArea, backwardArea) / min(forwardArea, backwardArea)
        guard areaRatio <= 2.5 else {
            return result(
                false,
                .areaRatioTooLarge,
                minimumConfidence: minimumConfidence,
                meanConfidence: meanConfidence,
                trackerIoU: trackerIoU,
                trackerCenterShift: trackerCenterShift,
                forwardMidpointIoU: forwardMidpointIoU,
                forwardMidpointShift: forwardMidpointShift,
                backwardMidpointIoU: backwardMidpointIoU,
                backwardMidpointShift: backwardMidpointShift,
                areaRatio: areaRatio
            )
        }

        return result(
            true,
            .confirmed,
            minimumConfidence: minimumConfidence,
            meanConfidence: meanConfidence,
            trackerIoU: trackerIoU,
            trackerCenterShift: trackerCenterShift,
            forwardMidpointIoU: forwardMidpointIoU,
            forwardMidpointShift: forwardMidpointShift,
            backwardMidpointIoU: backwardMidpointIoU,
            backwardMidpointShift: backwardMidpointShift,
            areaRatio: areaRatio
        )
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let a = lhs.standardized
        let b = rhs.standardized
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return 0 }
        let overlap = a.intersection(b)
        let overlapArea = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
        let unionArea =
            Double(a.width * a.height + b.width * b.height) - overlapArea
        guard unionArea > 0 else { return 0 }
        return max(0, min(1, overlapArea / unionArea))
    }

    static func centerShift(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        hypot(
            Double(lhs.midX - rhs.midX),
            Double(lhs.midY - rhs.midY)
        )
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func emitDiagnostic(_ diagnostic: SegmentVisualContinuityDiagnostic) {
        #if canImport(UIKit)
        let decision = diagnostic.shouldBridge ? "bridge" : "split"
        let message = String(
            format: "Segment visual continuity diagnostic: decision=%@ reason=%@ samples=%d/%d confidence=min %.3f mean %.3f tracker=iou %.3f shift %.3f midpoint=f %.3f/%.3f b %.3f/%.3f areaRatio=%.3f",
            decision,
            diagnostic.reason.rawValue,
            diagnostic.forwardCount,
            diagnostic.backwardCount,
            diagnostic.minimumConfidence ?? -1,
            diagnostic.meanConfidence ?? -1,
            diagnostic.trackerIoU ?? -1,
            diagnostic.trackerCenterShift ?? -1,
            diagnostic.forwardMidpointIoU ?? -1,
            diagnostic.forwardMidpointShift ?? -1,
            diagnostic.backwardMidpointIoU ?? -1,
            diagnostic.backwardMidpointShift ?? -1,
            diagnostic.areaRatio ?? -1
        )
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                DiagnosticLogger.log(message)
            }
        } else {
            Task { @MainActor in
                DiagnosticLogger.log(message)
            }
        }
        #endif
    }
}
