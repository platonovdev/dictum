import Application
import Domain
import Foundation

@MainActor
public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key = "com.onebtnvoice.settings"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() async throws -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .default
        }

        var settings = try decoder.decode(AppSettings.self, from: data)
        if settings.modelIdentifier == "large-v3" {
            settings.modelIdentifier = AppSettings.default.modelIdentifier
        }
        return settings
    }

    public func save(_ settings: AppSettings) async throws {
        let data = try encoder.encode(settings)
        defaults.set(data, forKey: key)
    }
}
