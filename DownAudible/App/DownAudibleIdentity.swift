import Foundation

nonisolated enum DownAudibleIdentity {
    private static let currentIdentifier = "com.tbmw.downaudible"
    private static let previousIdentifier = "uk.co.ashleycox.DownAudible"
    private static let preferencesMigrationKey = "MigratedPreviousBundlePreferences"

    static func migratePreferences(
        for bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        from previous: String = previousIdentifier,
        to current: String = currentIdentifier
    ) {
        guard bundleIdentifier == current else { return }

        let defaults = UserDefaults.standard
        var preferences = defaults.persistentDomain(forName: current) ?? [:]
        guard preferences[preferencesMigrationKey] == nil else { return }

        let previousPreferences = defaults.persistentDomain(forName: previous) ?? [:]
        preferences.merge(previousPreferences) { currentValue, _ in currentValue }
        preferences[preferencesMigrationKey] = true
        defaults.setPersistentDomain(preferences, forName: current)
    }

    static func audibleKeychainService(for bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        // Keep the existing service for the shipped app so credential reads and removals address the same items.
        let identifier = bundleIdentifier == currentIdentifier ? previousIdentifier : bundleIdentifier
        return (identifier ?? "DownAudible") + ".audible"
    }
}
