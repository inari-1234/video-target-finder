import UIKit

enum SegmentDiscoverySource: String, Sendable {
    case initial = "初回探索"
    case feedbackRescan = "学習再探索"
}


enum SegmentReviewState: String, CaseIterable, Identifiable {
    case unreviewed = "未判定"
    case confirmed = "正解"
    case rejected = "誤検出"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .unreviewed: return "questionmark.circle"
        case .confirmed: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        }
    }
}

/// Stage 6: 正解判定から作る追加見本。
/// 元フレーム全体ではなく、最も一致した局所領域を保存する。
struct LearnedReference: Identifiable {
    let id: UUID
    let sourceSegmentID: UUID
    let image: UIImage
    let sourceTime: TimeInterval

    init(sourceSegmentID: UUID, image: UIImage, sourceTime: TimeInterval) {
        self.id = UUID()
        self.sourceSegmentID = sourceSegmentID
        self.image = image
        self.sourceTime = sourceTime
    }
}

struct DetectedSegment: Identifiable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let bestTime: TimeInterval
    let bestDistance: Float
    let thumbnail: UIImage
    /// Feature Print比較で実際に最も一致した局所領域。再学習用。
    let matchThumbnail: UIImage
    let referenceIndex: Int
    let regionLabel: String
    let hitCount: Int
    /// 旧名trackingScore。実体は区間内サンプル時刻における連続Feature Printヒット率。
    let trackingScore: Double
    /// nearest / 上位2見本平均 / 中央値のA/B診断。採否には使用しない。
    let aggregationScores: ReferenceAggregationScores?
    var discoverySource: SegmentDiscoverySource

    var reviewState: SegmentReviewState = .unreviewed
    var isSelectedForExport: Bool = false

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        bestTime: TimeInterval,
        bestDistance: Float,
        thumbnail: UIImage,
        matchThumbnail: UIImage,
        referenceIndex: Int,
        regionLabel: String,
        hitCount: Int,
        trackingScore: Double,
        aggregationScores: ReferenceAggregationScores? = nil,
        discoverySource: SegmentDiscoverySource = .initial,
        reviewState: SegmentReviewState = .unreviewed,
        isSelectedForExport: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.bestTime = bestTime
        self.bestDistance = bestDistance
        self.thumbnail = thumbnail
        self.matchThumbnail = matchThumbnail
        self.referenceIndex = referenceIndex
        self.regionLabel = regionLabel
        self.hitCount = hitCount
        self.trackingScore = trackingScore
        self.aggregationScores = aggregationScores
        self.discoverySource = discoverySource
        self.reviewState = reviewState
        self.isSelectedForExport = isSelectedForExport
    }

    var rangeText: String {
        "\(ScanCandidate.format(startTime)) 〜 \(ScanCandidate.format(endTime))"
    }

    var durationText: String {
        String(format: "%.1f秒", max(0, endTime - startTime))
    }

    var distanceText: String {
        String(format: "%.4f", bestDistance)
    }

    var trackingText: String {
        String(format: "%.0f%%", min(1, max(0, trackingScore)) * 100)
    }
}

/// Stage 7: 詳細探索中は大量の候補が生じ得るため、画像は展開済みUIImageではなくJPEG Dataで保持する。
/// 最終的な区間代表画像だけをUIImageへ戻すことでピークメモリを抑える。
struct DetailedHit {
    let time: TimeInterval
    let distance: Float
    let thumbnailJPEG: Data
    let matchThumbnailJPEG: Data
    let referenceIndex: Int
    let regionLabel: String
    let aggregationScores: ReferenceAggregationScores
}
