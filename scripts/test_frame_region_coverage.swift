import CoreGraphics
import Foundation

@main
enum FrameRegionCoverageTests {
    static func coverage(of target: CGRect, by region: CGRect) -> Double {
        let visibleTarget = target.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !visibleTarget.isNull, visibleTarget.width > 0, visibleTarget.height > 0 else {
            return 0
        }
        let intersection = visibleTarget.intersection(region)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        return Double(
            (intersection.width * intersection.height) /
            (visibleTarget.width * visibleTarget.height)
        )
    }

    static func maxLocalCoverage(
        target: CGRect,
        mode: SearchSensitivity
    ) -> (coverage: Double, label: String) {
        var best = (coverage: 0.0, label: "")
        for region in FrameRegionSampler.regions(for: mode)
            where region.label != "画面全体" {
            let value = coverage(of: target, by: region.normalizedRect)
            if value > best.coverage {
                best = (value, region.label)
            }
        }
        return best
    }

    static func main() {
        let small = CGRect(
            x: 106.0 / 256.0,
            y: 101.0 / 256.0,
            width: 43.0 / 256.0,
            height: 54.0 / 256.0
        )
        let occludedBase = CGRect(
            x: 64.0 / 256.0,
            y: 68.0 / 256.0,
            width: 96.0 / 256.0,
            height: 120.0 / 256.0
        )
        let edge = CGRect(
            x: -20.0 / 256.0,
            y: 68.0 / 256.0,
            width: 96.0 / 256.0,
            height: 120.0 / 256.0
        )

        let smallBalanced = maxLocalCoverage(target: small, mode: .balanced)
        let occludedBalanced = maxLocalCoverage(target: occludedBase, mode: .balanced)
        let edgeBalanced = maxLocalCoverage(target: edge, mode: .balanced)

        precondition(smallBalanced.coverage >= 0.999)
        precondition(occludedBalanced.coverage >= 0.999)
        precondition(edgeBalanced.coverage >= 0.999)
        precondition(smallBalanced.label == "中央")
        precondition(occludedBalanced.label == "中央")
        precondition(edgeBalanced.label == "左帯")

        let smallFrameArea = Double(small.width * small.height)
        let originalFrameArea = Double(occludedBase.width * occludedBase.height)
        let edgeVisible = edge.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let edgeVisibleFraction = Double(
            (edgeVisible.width * edgeVisible.height) /
            (edge.width * edge.height)
        )
        let occlusionFraction = (96.0 * 44.0) / (96.0 * 120.0)

        print(String(
            format: "FrameRegion coverage: PASS | small area %.4f frame / %.3f original-target area | occlusion %.3f | edge visible %.3f | balanced labels small=%@ occluded=%@ edge=%@",
            smallFrameArea,
            smallFrameArea / originalFrameArea,
            occlusionFraction,
            edgeVisibleFraction,
            smallBalanced.label,
            occludedBalanced.label,
            edgeBalanced.label
        ))
    }
}
