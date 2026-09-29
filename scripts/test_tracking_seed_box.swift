import CoreGraphics
import Foundation

@main
enum TrackingSeedBoxDiagnosticsTests {
    static func approx(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= tolerance
    }

    static func main() {
        let grid = InstanceMaskLabelGrid(
            width: 4,
            height: 4,
            labels: [
                0,0,0,0,
                0,1,1,0,
                0,1,2,2,
                0,0,2,2
            ]
        )
        let boxes = TrackingSeedBoxAnalyzer.tightBoxes(grid: grid, instances: IndexSet([1,2]))
        precondition(boxes.count == 2)
        let one = boxes[0]
        let two = boxes[1]
        precondition(one.instanceIndex == 1)
        precondition(one.pixelCount == 3)
        precondition(one.localTopLeftRect == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        precondition(!one.touchesMaskEdge)
        precondition(two.touchesMaskEdge)

        let vision = TrackingSeedBoxAnalyzer.mapLocalTopLeftRectToVision(
            CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            searchRegionTopLeft: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        )
        guard let vision else { fatalError("vision rect missing") }
        precondition(abs(Double(vision.minX) - 0.35) < 0.0001)
        precondition(abs(Double(vision.minY) - 0.30) < 0.0001)
        precondition(abs(Double(vision.width) - 0.30) < 0.0001)
        precondition(abs(Double(vision.height) - 0.40) < 0.0001)

        precondition(approx(
            TrackingSeedBoxAnalyzer.intersectionOverUnion(
                CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5)
            ),
            1.0 / 3.0
        ))
        precondition(approx(
            TrackingSeedBoxAnalyzer.centerShift(
                CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                CGRect(x: 0.1, y: 0, width: 0.2, height: 0.2)
            ),
            0.1
        ))

        let stable = TrackingSeedCandidateDiagnostic(
            segmentID: UUID(),
            searchRegionArea: 0.36,
            samples: [
                TrackingSeedFrameSample(offsetSeconds: -0.25, visionRect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.3), featureDistance: 0.4, touchesSearchCropEdge: false),
                TrackingSeedFrameSample(offsetSeconds: 0, visionRect: CGRect(x: 0.21, y: 0.21, width: 0.2, height: 0.3), featureDistance: 0.39, touchesSearchCropEdge: false),
                TrackingSeedFrameSample(offsetSeconds: 0.25, visionRect: CGRect(x: 0.22, y: 0.22, width: 0.2, height: 0.3), featureDistance: 0.41, touchesSearchCropEdge: false)
            ]
        )
        let unstable = TrackingSeedCandidateDiagnostic(
            segmentID: UUID(),
            searchRegionArea: 0.36,
            samples: [
                TrackingSeedFrameSample(offsetSeconds: -0.25, visionRect: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1), featureDistance: 0.4, touchesSearchCropEdge: true),
                TrackingSeedFrameSample(offsetSeconds: 0, visionRect: CGRect(x: 0.60, y: 0.60, width: 0.1, height: 0.1), featureDistance: 0.39, touchesSearchCropEdge: true),
                TrackingSeedFrameSample(offsetSeconds: 0.25, visionRect: CGRect(x: 0.10, y: 0.10, width: 0.3, height: 0.3), featureDistance: 0.41, touchesSearchCropEdge: false)
            ]
        )
        guard let summary = TrackingSeedBoxAnalyzer.summarize(
            candidates: [stable, unstable],
            elapsedSeconds: 2.5,
            wasThermallyLimited: false,
            unsupportedMaskFormatCount: 1,
            frameFailureCount: 2
        ) else {
            fatalError("summary missing")
        }
        precondition(summary.candidateCount == 2)
        precondition(summary.centerSeedAvailableCount == 2)
        precondition(summary.threeFrameAvailableCount == 2)
        precondition(summary.centerEdgeTouchCount == 1)
        precondition(summary.stableSequenceCount == 1)
        precondition(summary.unsupportedMaskFormatCount == 1)
        precondition(summary.frameFailureCount == 2)
        precondition((summary.meanSeedToSearchAreaRatio ?? 0) > 0)

        print("TrackingSeedBoxDiagnostics tests: PASS")
    }
}
