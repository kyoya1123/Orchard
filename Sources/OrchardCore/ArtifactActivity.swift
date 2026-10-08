import CryptoKit
import Darwin
import Foundation

struct ArtifactOwner: Codable, Hashable, Sendable {
    let projectPath: String
    let worktreePath: String
    let repositoryPath: String

    static func resolve(_ project: XcodeProject) async throws -> Self {
        let root = try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "--show-toplevel"], currentDirectoryURL: project.rootURL)
        let common = try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"], currentDirectoryURL: project.rootURL)
        return Self(projectPath: project.fileURL.resolvingSymlinksInPath().path,
                    worktreePath: URL(fileURLWithPath: root).resolvingSymlinksInPath().path,
                    repositoryPath: URL(fileURLWithPath: common).deletingLastPathComponent().resolvingSymlinksInPath().path)
    }
}

struct ArtifactProject: Codable, Sendable {
    let owner: ArtifactOwner
    var lastUsedAt: Double
}

struct ArtifactSimulator: Codable, Sendable {
    let udid: String
    let name: String
    var owners: Set<ArtifactOwner>
    var lastUsedAt: Double
}

struct ArtifactStore: Sendable {
    let root: URL
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Orchard/Cleanup-v1")) { self.root = root }

    func projectURL(_ project: String) -> URL { root.appendingPathComponent("projects/\(Self.key(project)).json") }
    func simulatorURL(_ udid: String) -> URL { root.appendingPathComponent("simulators/\(Self.key(udid)).json") }
    func projectLock(_ project: String) -> URL { root.appendingPathComponent("locks/project-\(Self.key(project)).lock") }
    func simulatorLock(_ udid: String) -> URL { root.appendingPathComponent("locks/simulator-\(Self.key(udid)).lock") }

    static func key(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read<T: Decodable>(_ type: T.Type, at path: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: path))
    }

    func all<T: Decodable>(_ type: T.Type, in directory: String) throws -> [T] {
        let directory = root.appendingPathComponent(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(type, from: Data(contentsOf: $0)) }
    }

    func write<T: Encodable>(_ value: T, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: path, options: .atomic)
    }

    static func isStandardSimulator(_ name: String) -> Bool {
        name == "base" || ["iPhone", "iPad", "Apple", "Orchard Base "].contains { name.hasPrefix($0) }
    }
}

/// Shared leases cover builds and installation; the collector only tries an
/// exclusive lease. A busy project never makes background collection wait.
final class ArtifactLease: @unchecked Sendable {
    private var descriptor: Int32
    private let mutex = NSLock()
    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func tryAcquire(_ path: URL, shared: Bool = false) throws -> ArtifactLease? {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return ArtifactLease(fd)
    }

    static func acquire(_ path: URL, shared: Bool = true) async throws -> ArtifactLease {
        while true {
            try Task.checkCancellation()
            if let lease = try tryAcquire(path, shared: shared) { return lease }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func close() {
        mutex.lock()
        defer { mutex.unlock() }
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
    deinit { close() }
}

public final class ArtifactActivity: @unchecked Sendable {
    private let owner: ArtifactOwner
    private let store: ArtifactStore
    private var leases: [ArtifactLease]

    private init(owner: ArtifactOwner, store: ArtifactStore, lease: ArtifactLease) {
        self.owner = owner
        self.store = store
        self.leases = [lease]
    }

    public static func begin(project: XcodeProject, destination: XcodeDestination? = nil) async throws -> ArtifactActivity? {
        // A non-Git project cannot establish worktree ownership and is not
        // enrolled in automatic deletion.
        guard let owner = try? await ArtifactOwner.resolve(project) else { return nil }
        let store = ArtifactStore()
        let lease = try await ArtifactLease.acquire(store.projectLock(owner.projectPath))
        let activity = ArtifactActivity(owner: owner, store: store, lease: lease)
        try store.write(ArtifactProject(owner: owner, lastUsedAt: Date().timeIntervalSince1970),
                        to: store.projectURL(owner.projectPath))
        if let destination, destination.kind == .simulator {
            try await activity.useSimulator(udid: destination.id, name: destination.name)
        }
        BackgroundCleanup.schedule()
        return activity
    }

    public func useSimulator(udid: String, name: String) async throws {
        guard UUID(uuidString: udid) != nil, !ArtifactStore.isStandardSimulator(name) else { return }
        leases.append(try await ArtifactLease.acquire(store.simulatorLock(udid)))
        let update = try await ArtifactLease.acquire(store.root.appendingPathComponent("registry.lock"), shared: false)
        defer { update.close() }
        var record = try store.read(ArtifactSimulator.self, at: store.simulatorURL(udid))
            ?? ArtifactSimulator(udid: udid, name: name, owners: [], lastUsedAt: 0)
        guard record.name == name else { return }
        record.owners.insert(owner)
        record.lastUsedAt = Date().timeIntervalSince1970
        try store.write(record, to: store.simulatorURL(udid))
    }

    public func finish() {
        // The console can stay attached for days. Its lifetime must not pin
        // artifacts after the worktree has been removed.
        guard !leases.isEmpty else { return }
        try? store.write(ArtifactProject(owner: owner, lastUsedAt: Date().timeIntervalSince1970),
                         to: store.projectURL(owner.projectPath))
        for lease in leases { lease.close() }
        leases.removeAll()
        BackgroundCleanup.schedule()
    }
    deinit { finish() }
}

public enum BackgroundCleanup {
    public static func schedule() {
        Task.detached(priority: .background) { await launch() }
    }

    public static func launch() async {
        guard let executable = Bundle.main.executableURL, executable.lastPathComponent == "orchard" else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .background).async {
            defer { continuation.resume() }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["cleanup-worker"]
            process.qualityOfService = .background
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in }
            try? process.run()
        }
        }
    }
}
