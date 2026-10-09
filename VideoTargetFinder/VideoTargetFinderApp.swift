import SwiftUI

@main
struct VideoTargetFinderApp: App {
    @StateObject private var viewModel = VideoAnalysisViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
#if BEST_SHOT_B0A_DIAGNOSTICS
                .overlay(alignment: .bottomTrailing) {
                    BestShotB0ADiagnosticLauncher(asset: viewModel.videoAsset)
                        .padding()
                }
#endif
        }
    }
}
