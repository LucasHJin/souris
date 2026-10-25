import Foundation

/// Saves and loads `AppSettings` as JSON in `UserDefaults`.
enum SettingsStore {
  private static let key = "souris.settings"

  /// Returns the saved settings, or the defaults when nothing is saved or it can't be decoded.
  static func load() -> AppSettings {
    guard
      let data = UserDefaults.standard.data(forKey: key),
      let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
    else {
      return AppSettings()
    }
    return settings
  }

  static func save(_ settings: AppSettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }
}
