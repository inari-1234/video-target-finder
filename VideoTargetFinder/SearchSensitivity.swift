import Foundation

/// Stage 3 の探索量と候補の広さをまとめた設定。
enum SearchSensitivity: String, CaseIterable, Identifiable, Sendable {
    case fast = "高速"
    case balanced = "標準"
    case thorough = "高感度"

    var id: String { rawValue }

    /// 粗探索スコアのうち、どの程度を詳細探索候補として扱うか。
    var candidateQuantile: Double {
        switch self {
        case .fast: return 0.02
        case .balanced: return 0.04
        case .thorough: return 0.08
        }
    }

    /// 粗探索で保持する代表候補数。
    var coarseCandidateLimit: Int {
        switch self {
        case .fast: return 12
        case .balanced: return 18
        case .thorough: return 24
        }
    }

    /// 候補前後を詳細探索する秒数。
    var detailRadius: TimeInterval {
        switch self {
        case .fast: return 2.5
        case .balanced: return 4.0
        case .thorough: return 5.0
        }
    }

    var description: String {
        switch self {
        case .fast:
            return "全体＋大きな局所領域。まず速度を優先します。"
        case .balanced:
            return "小さめ・端の対象も探しつつ、処理量を抑えます。"
        case .thorough:
            return "重くなりますが、より細かい局所領域まで検索します。"
        }
    }
}
