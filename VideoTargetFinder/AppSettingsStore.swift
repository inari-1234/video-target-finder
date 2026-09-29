import Foundation

struct AppSettings: Codable, Equatable {
    var scanInterval: Double = 2.0
    var detailInterval: Double = 0.25
    var feedbackRescanInterval: Double = 1.0
    var sensitivityRawValue: String = SearchSensitivity.balanced.rawValue
    var leadPadding: Double = 1.0
    var trailPadding: Double = 1.0
    var exportMergeGap: Double = 0.25
    var exportModeRawValue: String = ExportMode.combined.rawValue
    var exportFormatRawValue: String = ExportFormat.movPreserve.rawValue

    static let defaults = AppSettings()
}

enum AppSettingsStore {
    private static let key = "VideoTargetFinder.AppSettings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .defaults
        }
        return decoded
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
