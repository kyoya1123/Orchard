import Foundation

/// Routes builds through `xcslot` when it is installed. xcslot builds in a
/// per-repository slot with its own DerivedData and only hands products out
/// through `--products-to`, so the slot's own paths are never launched.
struct XcslotBuilder: Sendable {
    let executableURL: URL
    let productsRoot: URL

    static let defaultProductsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Orchard/Products-v1")

    // Delegated runs and agents may have a minimal PATH.
    static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = XcslotBuilder.fallbackDirectories
    ) -> URL? {
        let override = environment["ORCHARD_XCSLOT"]
        if override == "0" { return nil }
        if let override, override.hasPrefix("/") {
            return isExecutableFile(override) ? URL(fileURLWithPath: override) : nil
        }

        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirectories + fallbackDirectories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("xcslot").path
            if isExecutableFile(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Keyed by destination: one run per destination is enforced, so this
    /// bounds disk use and keeps concurrent runs from sharing a directory.
    func productsDirectory(for destination: XcodeDestination) -> URL {
        productsRoot.appendingPathComponent(ArtifactStore.key(destination.id), isDirectory: true)
    }

    /// Installation copies the app, so a handed-out directory is only needed
    /// while its run builds and installs; a removed destination's would remain forever.
    func pruneStaleProducts(keeping destination: XcodeDestination, olderThan age: TimeInterval = 7 * 86400, now: Date = Date()) {
        let keep = productsDirectory(for: destination).lastPathComponent
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: productsRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries where entry.lastPathComponent != keep && entry.lastPathComponent.count == 64 {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < now.addingTimeInterval(-age) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Source package arguments are deliberately absent: the slot keeps its own
    /// warm SourcePackages, and per-worktree paths would defeat its incremental build.
    func arguments(
        project: XcodeProject,
        scheme: String,
        destination: XcodeDestination
    ) -> [String] {
        ["xcodebuild", "--products-to", productsDirectory(for: destination).path]
            + project.xcodebuildArguments
            + ["-scheme", scheme, "-destination", destination.xcodebuildDestination, "build"]
    }

    static func isInsideGitWorkTree(_ directory: URL) async -> Bool {
        let output = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path, "rev-parse", "--is-inside-work-tree"],
            currentDirectoryURL: nil
        )
        return output == "true"
    }
}
