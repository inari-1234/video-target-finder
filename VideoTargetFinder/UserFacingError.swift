import Foundation
import Photos

struct UserFacingError {
    let title: String
    let message: String
    let recovery: String?

    static func map(_ error: Error, context: String? = nil) -> UserFacingError {
        let ns = error as NSError
        let raw = ns.localizedDescription
        let lower = raw.lowercased()

        if lower.contains("icloud") || lower.contains("network") || lower.contains("internet") {
            return UserFacingError(
                title: "動画を取得できません",
                message: "iCloud上の動画を端末へ取得できなかった可能性があります。",
                recovery: "Wi‑Fi接続を確認し、写真アプリで動画を一度最後まで開いてから再試行してください。"
            )
        }

        if lower.contains("space") || lower.contains("disk") || ns.code == 640 {
            return UserFacingError(
                title: "空き容量が不足しています",
                message: "動画の解析または書き出しに必要な一時領域を確保できませんでした。",
                recovery: "iPhoneのストレージに余裕を作ってから再試行してください。元動画そのものを複製せず解析しますが、書き出し時には一時容量が必要です。"
            )
        }

        if lower.contains("cancel") {
            return UserFacingError(
                title: "処理を中断しました",
                message: "処理はキャンセルされました。",
                recovery: "粗探索のチェックポイントが残っていれば、続きから再開できます。"
            )
        }

        let prefix = context.map { "\($0)：" } ?? ""
        return UserFacingError(
            title: "処理に失敗しました",
            message: prefix + raw,
            recovery: "同じ操作で繰り返し発生する場合は、診断情報をコピーして確認してください。"
        )
    }
}
