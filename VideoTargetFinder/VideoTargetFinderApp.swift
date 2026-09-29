import SwiftUI

@main
struct VideoTargetFinderApp: App {
    @StateObject private var viewModel = VideoAnalysisViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
