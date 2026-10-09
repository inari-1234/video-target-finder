@preconcurrency import AVFoundation
import SwiftUI

#if BEST_SHOT_B0A_DIAGNOSTICS
struct BestShotB0ADiagnosticLauncher: View {
    let asset: AVAsset?

    @State private var showDiagnostics = false

    var body: some View {
        Button {
            showDiagnostics = true
        } label: {
            Label("B0-A診断", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(asset == nil)
        .accessibilityHint(asset == nil ? "先に動画を選択してください" : "選択済み動画のPTSフレーム抽出を診断します")
        .sheet(isPresented: $showDiagnostics) {
            if let asset {
                BestShotB0ADiagnosticsView(asset: asset)
            } else {
                ContentUnavailableView(
                    "動画が未選択です",
                    systemImage: "film",
                    description: Text("先に通常の「1. 解析する動画」で動画を選択してください。")
                )
            }
        }
    }
}
#endif
