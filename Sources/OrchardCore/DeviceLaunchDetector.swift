import Foundation

public enum DeviceLaunchDetector {
    /// Excludes app extensions (`.app/PlugIns/X.appex/X`), which can start without the app launching.
    public static func mainProcessIDs(
        appPath: String,
        processes: [(executable: String, processIdentifier: Int)]
    ) -> [Int] {
        let prefix = appPath.hasSuffix("/") ? appPath : "\(appPath)/"

        return processes.compactMap { process in
            guard let path = URL(string: process.executable)?.path,
                  path.hasPrefix(prefix) else {
                return nil
            }
            let remainder = path.dropFirst(prefix.count)
            return !remainder.isEmpty && !remainder.contains("/") ? process.processIdentifier : nil
        }
    }

    public static func hasNewLaunch(baseline: Set<Int>?, current: [Int]) -> Bool {
        guard let baseline else { return false }
        return current.contains { !baseline.contains($0) }
    }
}
