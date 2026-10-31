import Foundation

/// Where the machine list lives. Shared by the app and the `rdpm` command so both read the
/// same file, including a custom one on a network share or in iCloud Drive.
enum StoreLocation {
    static let appBundleID = "com.lanservices.rdpmanager"
    static let pathKey = "storeFilePath"
    static let environmentKey = "RDP_MANAGER_STORE"

    static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RDP Manager", isDirectory: true)

    static var defaultFileURL: URL { defaultDirectory.appendingPathComponent("machines.json") }

    /// The folder chosen in the app's Settings, read from its preferences. The command runs
    /// outside the app bundle, so it has to name the domain rather than use `standard`.
    static func configuredURL(
        defaults: UserDefaults? = UserDefaults(suiteName: appBundleID)
    ) -> URL? {
        guard let path = defaults?.string(forKey: pathKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// An explicit `--store` wins, then the environment, then the app's own setting, then
    /// the default location.
    static func resolve(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults? = UserDefaults(suiteName: appBundleID)
    ) -> URL {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        if let fromEnv = environment[environmentKey], !fromEnv.isEmpty {
            return URL(fileURLWithPath: (fromEnv as NSString).expandingTildeInPath)
        }
        return configuredURL(defaults: defaults) ?? defaultFileURL
    }

    static func load(_ url: URL) throws -> [Machine] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(StoreDocument.self, from: data).machines
    }
}
