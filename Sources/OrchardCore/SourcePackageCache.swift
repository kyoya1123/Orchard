import CryptoKit
import Darwin
import Foundation

/// Shares immutable SPM snapshots with APFS clones, never writable checkouts.
/// DerivedData remains under Xcode's control. A lease covers each xcodebuild
/// operation so GUI and CLI commands for the same project cannot race here.
public struct SourcePackageCache: Sendable {
    let root: URL
    let derivedDataRoot: URL
    let enabled: Bool

    public init() {
        self.init(
            root: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/Orchard/SourcePackages-v1"),
            derivedDataRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            enabled: ProcessInfo.processInfo.environment["ORCHARD_SPM_CACHE"] != "0"
        )
    }

    init(root: URL, derivedDataRoot: URL, enabled: Bool = true) {
        self.root = root.resolvingSymlinksInPath()
        self.derivedDataRoot = derivedDataRoot.resolvingSymlinksInPath()
        self.enabled = enabled
    }

    public func withCache<Value: Sendable>(
        project: XcodeProject,
        checkCancellation: @Sendable () throws -> Void = {},
        log: @Sendable (String) -> Void = { _ in },
        operation: @Sendable ([String]) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        try checkCancellation()
        let context: Context?
        do {
            context = try await self.context(for: project)
        } catch {
            try Task.checkCancellation()
            try checkCancellation()
            log("SPM cache unavailable: \(error.localizedDescription)\n")
            return try await operation([])
        }
        guard let context else { return try await operation([]) }
        return try await withCache(context: context, checkCancellation: checkCancellation, log: log, operation: operation)
    }

    func withCache<Value: Sendable>(
        context: Context,
        checkCancellation: @Sendable () throws -> Void = {},
        log: @Sendable (String) -> Void = { _ in },
        operation: @Sendable ([String]) async throws -> Value
    ) async throws -> Value {
        // Failure to lock must not fall through to an unprotected build.
        let lease = try await CacheLease.acquire(context.projectLock, checkCancellation: checkCancellation)
        defer { lease.unlock() }
        try Task.checkCancellation()
        try checkCancellation()
        do {
            try await prepare(context, checkCancellation: checkCancellation, log: log)
        } catch {
            try Task.checkCancellation()
            try checkCancellation()
            log("SPM clone skipped; Xcode will resolve packages normally: \(error.localizedDescription)\n")
        }
        // The selected directory is stable, including when a clone fails. Never
        // rerun a failed build or silently switch a populated package directory.
        let result = try await operation(["-clonedSourcePackagesDirPath", context.packages.path])
        try Task.checkCancellation()
        try checkCancellation()
        do {
            try await publish(context, checkCancellation: checkCancellation, log: log)
        } catch {
            try Task.checkCancellation()
            try checkCancellation()
            log("SPM template skipped: \(error.localizedDescription)\n")
        }
        return result
    }

    struct Context: Sendable {
        let lockfile: URL
        let resolved: Data
        let packages: URL
        let repositoryCache: URL
        let key: String
        let projectLock: URL
        var template: URL { repositoryCache.appendingPathComponent("templates/\(key)") }
        var templateLock: URL { repositoryCache.appendingPathComponent("templates.lock") }
    }

    func context(for project: XcodeProject) async throws -> Context? {
        guard enabled else { return nil }
        let lockfile = project.fileURL.appendingPathComponent(
            project.kind == .project
                ? "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
                : "xcshareddata/swiftpm/Package.resolved"
        )
        guard let resolved = try? Data(contentsOf: lockfile),
              !((try? Self.pins(in: resolved)) ?? [:]).isEmpty else { return nil }
        let commonDirectory = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            currentDirectoryURL: project.rootURL
        )
        let version = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-version"], currentDirectoryURL: project.rootURL
        )
        let developerDirectory: String
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            developerDirectory = override
        } else {
            developerDirectory = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                arguments: ["-p"], currentDirectoryURL: nil
            )
        }
        let repositoryCache = root.appendingPathComponent(Self.digest(Data(commonDirectory.utf8)))
        let projectID = Self.digest(Data(project.fileURL.resolvingSymlinksInPath().path.utf8))
        let managed = repositoryCache.appendingPathComponent("worktrees/\(projectID)/SourcePackages")
        // Reuse the project's existing standard Xcode checkout on first use;
        // do not replace, migrate, delete, or deduplicate someone else's files.
        let packages = FileManager.default.fileExists(atPath: managed.path)
            ? managed : (existingPackages(for: project) ?? managed)
        return Context(
            lockfile: lockfile, resolved: resolved, packages: packages,
            repositoryCache: repositoryCache,
            key: Self.cacheKey(resolved: resolved, toolchain: developerDirectory + "\n" + version),
            projectLock: repositoryCache.appendingPathComponent("locks/\(projectID).lock")
        )
    }

    func existingPackages(for project: XcodeProject) -> URL? {
        let expected = project.fileURL.resolvingSymlinksInPath().path
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: derivedDataRoot, includingPropertiesForKeys: nil
        )) ?? []
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = info["WorkspacePath"] as? String,
                  URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path == expected else { continue }
            let packages = directory.appendingPathComponent("SourcePackages")
            if FileManager.default.fileExists(atPath: packages.appendingPathComponent("workspace-state.json").path) {
                return packages
            }
        }
        return nil
    }

    static func cacheKey(resolved: Data, toolchain: String) -> String {
        digest(resolved + Data([0]) + Data(toolchain.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func prepare(
        _ context: Context, checkCancellation: @Sendable () throws -> Void,
        log: @Sendable (String) -> Void
    ) async throws {
        guard !FileManager.default.fileExists(atPath: context.packages.path) else { return }
        let lease = try await CacheLease.acquire(context.templateLock, checkCancellation: checkCancellation)
        defer { lease.unlock() }
        let source = context.template.appendingPathComponent("SourcePackages")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        log("SPM: cloning cached packages for this worktree.\n")
        try Self.stageClone(from: source, to: context.packages, checkCancellation: checkCancellation)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: context.template.path)
    }

    private func publish(
        _ context: Context, checkCancellation: @Sendable () throws -> Void,
        log: @Sendable (String) -> Void
    ) async throws {
        guard (try? Data(contentsOf: context.lockfile)) == context.resolved,
              FileManager.default.fileExists(atPath: context.packages.appendingPathComponent("workspace-state.json").path)
        else { return }
        let lease = try await CacheLease.acquire(context.templateLock, checkCancellation: checkCancellation)
        defer { lease.unlock() }
        guard !FileManager.default.fileExists(atPath: context.template.path) else { return }
        log("SPM: saving an APFS template for other worktrees.\n")
        let parent = context.template.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        let packages = stage.appendingPathComponent("SourcePackages")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let exclusions = try await Self.generatedWorkspacePaths(in: context.packages)
        try Self.cloneTree(from: context.packages, to: packages, checkCancellation: checkCancellation,
                           excluding: exclusions)
        try Self.rebase(packages, from: context.packages, to: packages)
        try await Self.validate(packages, resolved: context.resolved, checkCancellation: checkCancellation)
        guard (try? Data(contentsOf: context.lockfile)) == context.resolved else { return }
        try Self.rebase(packages, from: packages, to: context.template.appendingPathComponent("SourcePackages"))
        try FileManager.default.moveItem(at: stage, to: context.template)
        // Only immutable snapshots owned by this service are bounded. Worktree
        // checkouts (possibly edited) and Xcode's caches are never collected.
        let templates = try FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.count == 64 }
        let ordered = templates.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in ordered.dropFirst(3) where old != context.template {
            try FileManager.default.removeItem(at: old)
        }
    }

    static func stageClone(
        from source: URL, to destination: URL,
        checkCancellation: @Sendable () throws -> Void = {}
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try cloneTree(from: source, to: stage, checkCancellation: checkCancellation)
        try rebase(stage, from: source, to: destination)
        try Task.checkCancellation()
        try checkCancellation()
        // moveItem refuses an existing destination, so existing edits survive.
        try FileManager.default.moveItem(at: stage, to: destination)
    }

    static func cloneTree(
        from source: URL, to destination: URL,
        checkCancellation: @Sendable () throws -> Void,
        excluding: Set<String> = [],
        relativePath: String = ""
    ) throws {
        try Task.checkCancellation()
        try checkCancellation()
        let info = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        if info.isSymbolicLink != true, info.isDirectory == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                let relative = relativePath.isEmpty ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
                guard !excluding.contains(relative) else { continue }
                try cloneTree(from: child, to: destination.appendingPathComponent(child.lastPathComponent),
                              checkCancellation: checkCancellation, excluding: excluding, relativePath: relative)
            }
        } else {
            guard info.isRegularFile == true || info.isSymbolicLink == true else {
                throw OrchardError.message("Unsupported SPM cache entry: \(source.lastPathComponent)")
            }
            // Unlike cp -c, clonefile never falls back to a full data copy.
            guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func generatedWorkspacePaths(in root: URL) async throws -> Set<String> {
        var excluded = Set<String>()
        let checkouts = root.appendingPathComponent("checkouts")
        for name in try FileManager.default.contentsOfDirectory(atPath: checkouts.path) {
            let directory = checkouts.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".swiftpm").path) else { continue }
            let tracked = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["ls-files", "-z", "--", ".swiftpm"], currentDirectoryURL: directory
            )
            let ignored = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", ".swiftpm"],
                currentDirectoryURL: directory
            )
            // Preserve committed workspace files. Only ignored, generated IDE
            // files are excluded; other untracked edits still reject a snapshot.
            if tracked.isEmpty {
                let untracked = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                    arguments: ["ls-files", "-z", "--others", "--exclude-standard", "--", ".swiftpm"], currentDirectoryURL: directory
                )
                if untracked.isEmpty {
                    excluded.insert("checkouts/" + name + "/.swiftpm")
                    continue
                }
            }
            for path in ignored.split(separator: "\0") {
                excluded.insert("checkouts/" + name + "/" + path)
            }
        }
        return excluded
    }

    /// Rewrite only SPM state, Git metadata and internal symlinks. In particular,
    /// dependency source files are never searched/replaced or hard-linked.
    static func rebase(_ root: URL, from oldRoot: URL, to newRoot: URL) throws {
        let fm = FileManager.default
        // Relative names avoid Foundation's /var vs /private/var aliases.
        var pending = try fm.contentsOfDirectory(atPath: root.path)
        let old = oldRoot.path
        let new = newRoot.path
        func rewrite(_ value: String) -> String {
            value == old ? new : value.replacingOccurrences(of: old + "/", with: new + "/")
        }
        while let relative = pending.popLast() {
            try Task.checkCancellation()
            let file = root.appendingPathComponent(relative)
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if info.isSymbolicLink != true, info.isDirectory == true {
                pending += try fm.contentsOfDirectory(atPath: file.path).map { relative + "/" + $0 }
                continue
            }
            if info.isSymbolicLink == true {
                let target = try fm.destinationOfSymbolicLink(atPath: file.path)
                let original = oldRoot.appendingPathComponent(relative)
                let resolved = URL(fileURLWithPath: target, relativeTo: original.deletingLastPathComponent()).standardizedFileURL.path
                guard resolved.hasPrefix(old + "/") else {
                    throw OrchardError.message("SPM snapshot has an external symbolic link")
                }
                if target.hasPrefix("/"), rewrite(target) != target {
                    try fm.removeItem(at: file)
                    try fm.createSymbolicLink(atPath: file.path, withDestinationPath: rewrite(target))
                }
                continue
            }
            guard info.isRegularFile == true else { continue }
            let isState = relative == "workspace-state.json"
            let isGit = (relative.contains("/.git/") || relative.hasSuffix("/.git") || relative.hasPrefix("repositories/"))
                && ["config", "alternates", ".git", "gitdir", "commondir"].contains(file.lastPathComponent)
            guard isState || isGit else { continue }
            let original = try Data(contentsOf: file)
            let updated: Data
            if isState {
                func rewriteJSON(_ value: Any) -> Any {
                    if let text = value as? String {
                        return text == old || text.hasPrefix(old + "/") ? rewrite(text) : text
                    }
                    if let array = value as? [Any] { return array.map(rewriteJSON) }
                    if let object = value as? [String: Any] { return object.mapValues(rewriteJSON) }
                    return value
                }
                let json = try JSONSerialization.jsonObject(with: original)
                updated = try JSONSerialization.data(withJSONObject: rewriteJSON(json), options: [.sortedKeys])
            } else {
                guard let text = String(data: original, encoding: .utf8) else {
                    throw OrchardError.message("Unsupported Git metadata encoding")
                }
                // Alternates/gitdir must not keep using the original cache or
                // another worktree's object database after the clone is seeded.
                if ["alternates", ".git", "gitdir", "commondir"].contains(file.lastPathComponent) {
                    let originalFile = oldRoot.appendingPathComponent(relative)
                    let base = file.lastPathComponent == "alternates"
                        ? originalFile.deletingLastPathComponent().deletingLastPathComponent()
                        : originalFile.deletingLastPathComponent()
                    for line in text.split(separator: "\n") {
                        let path = String(line).replacingOccurrences(of: "gitdir: ", with: "")
                        let target = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
                        guard target.hasPrefix(old + "/") else {
                            throw OrchardError.message("SPM snapshot has external Git storage")
                        }
                    }
                }
                updated = Data(rewrite(text).utf8)
            }
            if updated != original {
                let mode = (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: file.path)
                defer { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
                try updated.write(to: file)
            }
        }
    }

    struct Pin: Equatable {
        let location: String
        let revision: String
    }

    static func pins(in data: Data) throws -> [String: Pin] {
        // Unknown formats, local/registry dependencies and old lockfile formats
        // keep Xcode's normal behavior; never guess their cache identity.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? Int, [2, 3].contains(version),
              let pins = json["pins"] as? [[String: Any]] else { throw OrchardError.message("Unsupported Package.resolved") }
        var result: [String: Pin] = [:]
        for pin in pins {
            guard pin["kind"] as? String == "remoteSourceControl",
                  let identity = pin["identity"] as? String,
                  let location = pin["location"] as? String,
                  let state = pin["state"] as? [String: Any], let revision = state["revision"] as? String,
                  result[identity] == nil else { throw OrchardError.message("Unsupported package pin") }
            result[identity] = Pin(location: location, revision: revision)
        }
        return result
    }

    static func validate(
        _ root: URL, resolved: Data,
        checkCancellation: @Sendable () throws -> Void = {}
    ) async throws {
        let expected = try pins(in: resolved)
        let data = try Data(contentsOf: root.appendingPathComponent("workspace-state.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = json["object"] as? [String: Any],
              let dependencies = object["dependencies"] as? [[String: Any]],
              dependencies.count == expected.count else { throw OrchardError.message("SPM state does not match pins") }
        for artifact in object["artifacts"] as? [[String: Any]] ?? [] {
            guard let path = artifact["path"] as? String,
                  path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: path) else {
                throw OrchardError.message("SPM artifact is missing or outside the snapshot")
            }
        }
        var seen = Set<String>()
        for dependency in dependencies {
            try Task.checkCancellation()
            try checkCancellation()
            guard let ref = dependency["packageRef"] as? [String: Any],
                  let identity = ref["identity"] as? String, let pin = expected[identity], seen.insert(identity).inserted,
                  ref["kind"] as? String == "remoteSourceControl", ref["location"] as? String == pin.location,
                  let state = dependency["state"] as? [String: Any], state["name"] as? String == "sourceControlCheckout",
                  let checkout = state["checkoutState"] as? [String: Any], checkout["revision"] as? String == pin.revision,
                  let subpath = dependency["subpath"] as? String, !subpath.isEmpty,
                  subpath != ".", subpath != "..", !subpath.contains("/") else {
                throw OrchardError.message("SPM snapshot includes unpinned or edited dependencies")
            }
            let directory = root.appendingPathComponent("checkouts/\(subpath)")
            let head = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["rev-parse", "HEAD"], currentDirectoryURL: directory
            )
            let status = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain",
                            "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"],
                currentDirectoryURL: directory
            )
            guard head == pin.revision, status.isEmpty else { throw OrchardError.message("SPM checkout is modified: \(identity)") }
        }
    }
}

/// flock is process-wide coordination (an actor alone would not cover CLI).
/// Nonblocking attempts keep the executor responsive and the wait cancellable.
final class CacheLease: @unchecked Sendable {
    private var descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(_ path: URL, checkCancellation: @Sendable () throws -> Void = {}) async throws -> CacheLease {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let lease = CacheLease(descriptor)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try Task.checkCancellation()
            try checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        try checkCancellation()
        return lease
    }

    func unlock() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
    deinit { unlock() }
}
