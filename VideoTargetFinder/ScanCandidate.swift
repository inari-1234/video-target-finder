import UIKit

struct ScanCandidate: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let distance: Float
    let thumbnail: UIImage
    let referenceIndex: Int
    let regionLabel: String

    var timeText: String { Self.format(time) }

    var distanceText: String {
        String(format: "%.4f", distance)
    }

    static func format(_ time: TimeInterval) -> String {
        let totalMilliseconds = max(0, Int((time * 1000).rounded()))
        let totalSeconds = totalMilliseconds / 1000
        let milliseconds = totalMilliseconds % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        }
        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }
}
