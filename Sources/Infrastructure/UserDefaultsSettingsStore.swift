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

        let settings = try decoder.decode(AppSettings.self, from: data)
        // Re-encode after schema migrations. This permanently removes legacy
        // cloud configuration and API-key fields from UserDefaults instead of
        // merely ignoring them in memory.
        let sanitizedData = try encoder.encode(settings)
        if sanitizedData != data {
            defaults.set(sanitizedData, forKey: key)
        }
        return settings
    }

    public func save(_ settings: AppSettings) async throws {
        let data = try encoder.encode(settings)
        defaults.set(data, forKey: key)
    }
}
