import Foundation
import AVFoundation

struct ExportTimeRange: Identifiable, Equatable {
    let id = UUID()
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }

    var cmTimeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    var rangeText: String {
        "\(ScanCandidate.format(start)) 〜 \(ScanCandidate.format(end))"
    }
}

enum ExportMode: String, CaseIterable, Identifiable {
    case individual = "個別クリップ"
    case combined = "1本に結合"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .individual:
            return "重複・近接区間を整理したあと、各区間を別々の動画としてアプリ内へ安全保存します。"
        case .combined:
            return "選択区間を元動画の時系列順にまとめ、1本の動画としてアプリ内へ安全保存します。"
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case movPreserve = "MOV・画質維持"
    case mp4Compatible = "MP4・互換性"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .movPreserve: return "mov"
        case .mp4Compatible: return "mp4"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .movPreserve: return .mov
        case .mp4Compatible: return .mp4
        }
    }

    var presetName: String {
        switch self {
        case .movPreserve:
            return AVAssetExportPresetPassthrough
        case .mp4Compatible:
            return AVAssetExportPresetHighestQuality
        }
    }

    /// 複数区間のcomposition書き出しではPassthroughを避ける。
    /// PhotoKit由来の動画＋複数セグメント結合でAVFoundation内部終了を起こしにくくするため、
    /// MOVでも結合時だけ再エンコードを許可して安定性を優先する。
    var combinedPresetName: String {
        switch self {
        case .movPreserve:
            return AVAssetExportPresetHEVCHighestQuality
        case .mp4Compatible:
            return AVAssetExportPresetHighestQuality
        }
    }

    var description: String {
        switch self {
        case .movPreserve:
            return "個別クリップは再エンコードを極力回避。1本に結合する場合は高品質HEVCで容量を抑え、アプリ内へ安全保存します。"
        case .mp4Compatible:
            return "MP4へ高品質で書き出します。MOVより時間・発熱・一時容量が増える場合があります。"
        }
    }
}
