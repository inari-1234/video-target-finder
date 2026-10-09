@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import SwiftUI
import UIKit

struct BestShotB0ADiagnosticSample: Identifiable, Sendable {
    let ordinal: Int
    let expectedPTS: BestShotFramePTS
    let actualPTS: BestShotFramePTS
    let exactMatch: Bool
    let pixelFormat: OSType
    let width: Int
    let height: Int

    var id: Int { ordinal }
}

struct BestShotB0ADiagnosticReport: Sendable {
    let frameCount: Int
    let nominalFrameRate: Float
    let isVariableFrameRate: Bool
    let sourceDynamicRange: BestShotDynamicRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let samples: [BestShotB0ADiagnosticSample]
    let elapsedSeconds: TimeInterval

    var exactMatchCount: Int {
        samples.filter(\.exactMatch).count
    }

    var exactMatchRate: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(exactMatchCount) / Double(samples.count)
    }

    var currentVideoPassesExactPTSGate: Bool {
        !samples.isEmpty && exactMatchCount == samples.count
    }

    var displaySize: CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    var text: String {
        let transform = preferredTransform
        var lines: [String] = [
            "Video Target Finder / Best Shot B0-A 実機診断",
            "Frame authority: presentation PTS + sync-anchor decode",
            "Frames: \(frameCount)",
            String(format: "Nominal FPS: %.3f", nominalFrameRate),
            "Variable timing: \(isVariableFrameRate ? "YES" : "NO")",
            "Dynamic range: \(sourceDynamicRange.rawValue)",
            "Natural size: \(Int(naturalSize.width))x\(Int(naturalSize.height))",
            "Display size: \(Int(displaySize.width))x\(Int(displaySize.height))",
            String(format: "Preferred transform: [%.4f %.4f %.4f %.4f %.4f %.4f]", transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty),
            String(format: "Exact PTS: %d/%d (%.1f%%)", exactMatchCount, samples.count, exactMatchRate * 100),
            String(format: "Elapsed: %.3fs", elapsedSeconds),
            "Current-video gate: \(currentVideoPassesExactPTSGate ? "PASS" : "FAIL")",
            "Samples:"
        ]
        for sample in samples {
            lines.append(
                String(
                    format: "  #%d expected=%.6f actual=%.6f exact=%@ format=%@ size=%dx%d",
                    sample.ordinal,
                    sample.expectedPTS.seconds,
                    sample.actualPTS.seconds,
                    sample.exactMatch ? "YES" : "NO",
                    Self.fourCC(sample.pixelFormat),
                    sample.width,
                    sample.height
                )
            )
        }
        lines.append("Note: B0-A overall PASS requires representative SDR/VFR/HDR/portrait/Photos-edited source coverage; this report evaluates only the currently selected video.")
        return lines.joined(separator: "\n")
    }

    static func sampleOrdinals(frameCount: Int) -> [Int] {
        guard frameCount > 0 else { return [] }
        let last = frameCount - 1
        let candidates = [0, last / 4, last / 2, (last * 3) / 4, last]
        var result: [Int] = []
        for ordinal in candidates where !result.contains(ordinal) {
            result.append(ordinal)
        }
        return result
    }

    static func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        return String(format: "0x%08X", value)
    }
}

struct BestShotB0ADiagnosticsView: View {
    let asset: AVAsset

    @Environment(\.dismiss) private var dismiss
    @State private var isRunning = false
    @State private var phase = "未実行"
    @State private var report: BestShotB0ADiagnosticReport?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("B0-A フレーム抽出Authority") {
                    Text("この診断は通常の推し探索・候補順位・動画書き出しを変更しません。選択済み動画の実PTSを列挙し、代表5点をsync sampleから再デコードして同一PTSか確認します。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await runDiagnostics() }
                    } label: {
                        Label(isRunning ? "診断中…" : "この動画を診断", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)

                    if isRunning {
                        ProgressView(phase)
                    } else {
                        Text("状態: \(phase)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let report {
                    Section("結果") {
                        LabeledContent("この動画のPTS Gate", value: report.currentVideoPassesExactPTSGate ? "PASS" : "FAIL")
                        LabeledContent("PTS一致", value: "\(report.exactMatchCount) / \(report.samples.count)")
                        LabeledContent("総フレーム", value: "\(report.frameCount)")
                        LabeledContent("VFR判定", value: report.isVariableFrameRate ? "YES" : "NO")
                        LabeledContent("Dynamic Range", value: report.sourceDynamicRange.rawValue.uppercased())
                        LabeledContent("元解像度", value: "\(Int(report.naturalSize.width)) × \(Int(report.naturalSize.height))")
                        LabeledContent("表示向き反映後", value: "\(Int(report.displaySize.width)) × \(Int(report.displaySize.height))")
                        LabeledContent("所要時間", value: String(format: "%.2f秒", report.elapsedSeconds))
                    }

                    Section("代表PTS") {
                        ForEach(report.samples) { sample in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("#\(sample.ordinal)  \(sample.exactMatch ? "一致" : "不一致")")
                                    .font(.headline)
                                Text(String(format: "expected %.6f / actual %.6f", sample.expectedPTS.seconds, sample.actualPTS.seconds))
                                    .font(.caption.monospacedDigit())
                                Text("\(BestShotB0ADiagnosticReport.fourCC(sample.pixelFormat))  \(sample.width)×\(sample.height)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        Button("診断結果をコピー") {
                            UIPasteboard.general.string = report.text
                        }
                        Text("B0-A全体のPASSには、この1本だけでなくSDR/VFR/HDR/縦向き/写真アプリ編集済み等の代表ソース確認が必要です。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText {
                    Section("診断エラー") {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("B0-A 実機診断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .disabled(isRunning)
                }
            }
        }
    }

    @MainActor
    private func runDiagnostics() async {
        guard !isRunning else { return }
        isRunning = true
        phase = "PTS一覧を作成中…"
        report = nil
        errorText = nil
        let startedAt = Date()

        do {
            let index = try await BestShotFrameAuthority.makeIndex(for: asset)
            let ordinals = BestShotB0ADiagnosticReport.sampleOrdinals(frameCount: index.frameCount)
            var samples: [BestShotB0ADiagnosticSample] = []
            samples.reserveCapacity(ordinals.count)

            for (position, ordinal) in ordinals.enumerated() {
                phase = "代表フレームを確認中… \(position + 1) / \(ordinals.count)"
                let decoded = try await BestShotFrameAuthority.decodeExactFrame(
                    from: asset,
                    index: index,
                    ordinal: ordinal
                )
                samples.append(
                    BestShotB0ADiagnosticSample(
                        ordinal: ordinal,
                        expectedPTS: decoded.expectedPTS,
                        actualPTS: decoded.actualPTS,
                        exactMatch: decoded.isExactPTSMatch,
                        pixelFormat: decoded.pixelFormat,
                        width: CVPixelBufferGetWidth(decoded.pixelBuffer),
                        height: CVPixelBufferGetHeight(decoded.pixelBuffer)
                    )
                )
                await Task.yield()
            }

            report = BestShotB0ADiagnosticReport(
                frameCount: index.frameCount,
                nominalFrameRate: index.nominalFrameRate,
                isVariableFrameRate: index.isVariableFrameRate,
                sourceDynamicRange: index.sourceDynamicRange,
                naturalSize: index.naturalSize,
                preferredTransform: index.preferredTransform,
                samples: samples,
                elapsedSeconds: max(0, Date().timeIntervalSince(startedAt))
            )
            phase = report?.currentVideoPassesExactPTSGate == true ? "この動画: PASS" : "この動画: FAIL"
        } catch {
            errorText = error.localizedDescription
            phase = "FAIL"
        }

        isRunning = false
    }
}
