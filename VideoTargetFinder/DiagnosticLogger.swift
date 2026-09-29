import Foundation
import UIKit

@MainActor
enum DiagnosticLogger {
    private static let maxBytes = 250_000

    static func log(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try data.write(to: logURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
            trimIfNeeded()
        } catch {
            // 診断ログ失敗が本処理を止めないよう無視する。
        }
    }

    static func report(extra: String = "") -> String {
        let device = UIDevice.current
        let header = """
        Video Target Finder - Diagnostic Report
        Generated: \(timestamp())
        App: \(appVersionText())
        Device: \(device.model)
        System: \(device.systemName) \(device.systemVersion)
        Thermal: \(thermalLabel(ProcessInfo.processInfo.thermalState))
        Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "OFF")
        \(extra)
        --- Log ---
        """
        return header + "\n" + readLog()
    }

    static func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }

    private static func readLog() -> String {
        guard let data = try? Data(contentsOf: logURL),
              let string = String(data: data, encoding: .utf8) else {
            return "(no log)"
        }
        return string
    }

    private static func trimIfNeeded() {
        guard let data = try? Data(contentsOf: logURL), data.count > maxBytes else { return }
        let tail = data.suffix(maxBytes / 2)
        try? Data(tail).write(to: logURL, options: .atomic)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func appVersionText() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (Build \(build))"
    }

    private static var logURL: URL {
        PersistentStorageLayout.diagnosticLogURL(
            in: PersistentStorageLayout.applicationSupportRoot()
        )
    }
}
