@preconcurrency import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class SegmentPreviewPlayer: ObservableObject {
    let player: AVPlayer
    let startTime: TimeInterval
    let endTime: TimeInterval

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval

    private var boundaryObserver: Any?
    private var periodicObserver: Any?
    private var isCleanedUp = false

    init(asset: AVAsset, startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = max(0, startTime)
        self.endTime = max(startTime, endTime)
        self.currentTime = max(0, startTime)
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        installObservers()
        seekToStart(autoplay: false)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        if player.currentTime().seconds >= endTime - 0.05 || player.currentTime().seconds < startTime - 0.05 {
            seekToStart(autoplay: true)
            return
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func restart() {
        seekToStart(autoplay: true)
    }

    func stop() {
        player.pause()
        isPlaying = false
        removeObserversIfNeeded()
    }

    private func removeObserversIfNeeded() {
        guard !isCleanedUp else { return }
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        if let periodicObserver {
            player.removeTimeObserver(periodicObserver)
            self.periodicObserver = nil
        }
        isCleanedUp = true
    }

    private func seekToStart(autoplay: Bool) {
        let target = CMTime(seconds: startTime, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            guard let self else { return }
            Task { @MainActor in
                guard finished else { return }
                self.currentTime = self.startTime
                if autoplay {
                    self.player.play()
                    self.isPlaying = true
                }
            }
        }
    }

    private func installObservers() {
        let boundary = NSValue(time: CMTime(seconds: endTime, preferredTimescale: 600))
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [boundary], queue: .main) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.player.pause()
                self.isPlaying = false
                self.currentTime = self.endTime
            }
        }

        let interval = CMTime(seconds: 0.10, preferredTimescale: 600)
        periodicObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.currentTime = min(self.endTime, max(self.startTime, seconds))
                if seconds >= self.endTime {
                    self.player.pause()
                    self.isPlaying = false
                }
            }
        }
    }
}

struct SegmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: SegmentPreviewPlayer
    let title: String

    init(asset: AVAsset, startTime: TimeInterval, endTime: TimeInterval, title: String) {
        _controller = StateObject(
            wrappedValue: SegmentPreviewPlayer(
                asset: asset,
                startTime: startTime,
                endTime: endTime
            )
        )
        self.title = title
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: controller.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text(ScanCandidate.format(controller.currentTime))
                        .monospacedDigit()
                    Spacer()
                    Text(ScanCandidate.format(controller.endTime))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                ProgressView(
                    value: max(0, controller.currentTime - controller.startTime),
                    total: max(0.001, controller.endTime - controller.startTime)
                )

                HStack(spacing: 12) {
                    Button {
                        controller.restart()
                    } label: {
                        Label("最初から", systemImage: "backward.end.fill")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        controller.togglePlayback()
                    } label: {
                        Label(
                            controller.isPlaying ? "一時停止" : "再生",
                            systemImage: controller.isPlaying ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text("このプレビューは候補区間の終端で自動停止します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") {
                        controller.stop()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                controller.stop()
            }
        }
    }
}
