import CoreGraphics
import Foundation

enum SegmentContinuityAnalyzer {
    static func shouldBridge(
        forward: [VisionTrackingFrameOutput],
        backward: [VisionTrackingFrameOutput],
        midpointReferenceRect: CGRect?
    ) -> Bool {
        guard forward.count >= 2,
              backward.count >= 2,
              let midpointReferenceRect,
              !midpointReferenceRect.isNull,
              midpointReferenceRect.width > 0,
              midpointReferenceRect.height > 0,
              !forward.contains(where: { $0.requestFailed || $0.boundingBox == nil }),
              !backward.contains(where: { $0.requestFailed || $0.boundingBox == nil }),
              let forwardMidpoint = forward.last?.boundingBox,
              let backwardMidpoint = backward.last?.boundingBox else {
            return false
        }

        let confidences = (forward + backward).compactMap(\.confidence).map(Double.init)
        guard confidences.count == forward.count + backward.count,
              let minimumConfidence = confidences.min(),
              minimumConfidence >= 0.25,
              average(confidences) >= 0.45 else {
            return false
        }

        let trackersAgree =
            intersectionOverUnion(forwardMidpoint, backwardMidpoint) >= 0.35 ||
            centerShift(forwardMidpoint, backwardMidpoint) <= 0.10
        guard trackersAgree else { return false }

        let forwardMatchesMidpoint =
            intersectionOverUnion(forwardMidpoint, midpointReferenceRect) >= 0.20 ||
            centerShift(forwardMidpoint, midpointReferenceRect) <= 0.15
        let backwardMatchesMidpoint =
            intersectionOverUnion(backwardMidpoint, midpointReferenceRect) >= 0.20 ||
            centerShift(backwardMidpoint, midpointReferenceRect) <= 0.15
        guard forwardMatchesMidpoint, backwardMatchesMidpoint else { return false }

        let forwardArea = Double(forwardMidpoint.width * forwardMidpoint.height)
        let backwardArea = Double(backwardMidpoint.width * backwardMidpoint.height)
        guard forwardArea > 0, backwardArea > 0 else { return false }
        let areaRatio = max(forwardArea, backwardArea) / min(forwardArea, backwardArea)
        return areaRatio <= 2.5
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
}
