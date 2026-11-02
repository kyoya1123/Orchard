import Foundation

/// Orchard's settings live in `~/Library/Preferences/dev.codex.Orchard.plist`,
/// the domain the former menu bar app wrote, so existing settings keep working.
public enum AppConfiguration {
    public static let suiteName = "dev.codex.Orchard"

    public enum Keys {
        public static let configuredDirectoryPaths = "configuredDirectoryPaths"
        public static let simslimExceptCategories = "simslimExceptCategories"
    }

    public static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Extra directories to scan for worktrees (`defaults write dev.codex.Orchard configuredDirectoryPaths -array <path> ...`).
    public static func configuredDirectoryPaths() -> [String] {
        sharedDefaults().stringArray(forKey: Keys.configuredDirectoryPaths) ?? []
    }
}
