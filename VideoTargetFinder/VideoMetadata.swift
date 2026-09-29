import Foundation
import CoreGraphics

struct VideoMetadata: Equatable {
    let duration: TimeInterval
    let displaySize: CGSize
    let nominalFrameRate: Float

    var durationText: String {
        guard duration.isFinite, duration >= 0 else { return "不明" }
        let safe = min(duration.rounded(), Double(Int.max))
        let total = max(0, Int(safe))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var resolutionText: String {
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width >= 0, displaySize.height >= 0 else {
            return "不明"
        }
        let width = Int(min(displaySize.width.rounded(), CGFloat(Int.max)))
        let height = Int(min(displaySize.height.rounded(), CGFloat(Int.max)))
        return "\(width) × \(height)"
    }

    var frameRateText: String {
        guard nominalFrameRate.isFinite, nominalFrameRate > 0 else { return "不明" }
        return String(format: "%.2f fps", nominalFrameRate)
    }
}
