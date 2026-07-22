import Foundation

/// Slims simulators with simslim (https://github.com/MobAI-App/simslim) so they
/// boot without unneeded background daemons. Slim state persists in the
/// simulator's own launchd overrides, so slimming runs once per simulator. The
/// marker file lives inside the simulator's data directory: `simctl erase`
/// wipes the slim state and the marker together, so the next run re-slims.
public enum SimSlimService {
    /// Daemon categories left enabled. Override with
    /// `defaults write dev.codex.Orchard simslimExceptCategories -array store widgets`.
    /// The default keeps StoreKit (store) and Live Activity (widgets) testing working.
    static func exceptCategories() -> [String] {
        AppConfiguration.sharedDefaults()
            .stringArray(forKey: AppConfiguration.Keys.simslimExceptCategories) ?? ["store", "widgets"]
    }

    static func simslimURL() -> URL? {
        for path in ["/opt/homebrew/bin/simslim", "/usr/local/bin/simslim"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func markerURL(udid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Developer/CoreSimulator/Devices/\(udid)/data/.simslim-applied"
        )
    }

    /// Returns a task only when slimming is actually needed (nil when simslim is
    /// not installed or the simulator is already slim). Meant to run concurrently
    /// with the build and be awaited right before boot. A failed slim never fails
    /// the run.
    public static func slimTaskIfNeeded(
        udid: String,
        log: @Sendable @escaping (String) -> Void
    ) -> Task<Void, Never>? {
        guard let simslim = simslimURL(),
              !FileManager.default.fileExists(atPath: markerURL(udid: udid).path)
        else { return nil }

        var arguments = ["on", udid]
        let except = exceptCategories()
        if !except.isEmpty {
            arguments += ["--except", except.joined(separator: ",")]
        }
        return Task.detached {
            log("$ simslim \(arguments.joined(separator: " "))\n")
            do {
                _ = try await ProcessRunner.run(
                    executableURL: simslim,
                    arguments: arguments,
                    currentDirectoryURL: nil
                )
                FileManager.default.createFile(atPath: markerURL(udid: udid).path, contents: nil)
                log("simslim: simulator slimmed.\n")
            } catch {
                log("simslim failed; continuing with the stock configuration: \(error.localizedDescription)\n")
            }
        }
    }
}
