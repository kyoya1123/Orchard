import Foundation

/// Single source of truth for where Orchard persists its settings and under
/// which keys. The GUI writes through `UserDefaults.standard` (whose domain is
/// the app's bundle id when launched as a bundle), while the CLI — which runs
/// as a bare binary with no bundle id — must address the same plist explicitly
/// by suite name. Both paths resolve to
/// `~/Library/Preferences/dev.codex.Orchard.plist`.
public enum AppConfiguration {
    public static let suiteName = "dev.codex.Orchard"

    public enum Keys {
        public static let configuredDirectoryPaths = "configuredDirectoryPaths"
        public static let favoriteSimulatorDestinationIDs = "favoriteSimulatorDestinationIDs"
        public static let globalHotKey = "globalHotKey"
        public static let schemeCache = "schemeCache"
        public static let onboardingCompleted = "onboardingCompleted"
    }

    /// UserDefaults holding Orchard's settings, resolved correctly whether
    /// the caller is the bundled app or a bare CLI binary. When launched from
    /// the bundle, the process's own bundle id already equals `suiteName`, so
    /// `UserDefaults.standard` targets the right domain — and passing that id as
    /// a suite name is rejected by Foundation ("nonsensical suite"). When run as
    /// a bare binary (no bundle id), the suite name is what points at the
    /// shared plist.
    public static func sharedDefaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == suiteName {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Directories the user configured in the GUI to scan for worktrees.
    public static func configuredDirectoryPaths() -> [String] {
        sharedDefaults().stringArray(forKey: Keys.configuredDirectoryPaths) ?? []
    }
}
