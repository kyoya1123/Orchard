import Foundation

/// File-based store for `RunRecord`s shared between the CLI and the GUI. Each
/// run is one `<id>.json` file under
/// `~/Library/Application Support/Orchard/runs/`. The CLI writes/updates its
/// file as a run progresses; the GUI polls `loadAll()` to mirror those runs in
/// its Runs list. Both processes resolve the same user-domain path.
public struct RunStore: Sendable {
    public static let shared = RunStore()

    public init() {}

    public var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Orchard", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Creates the store directory if needed and returns it. Useful for setting
    /// up a filesystem watcher that requires the path to exist.
    @discardableResult
    public func prepareDirectory() -> URL {
        try? ensureDirectory()
        return directoryURL
    }

    private func fileURL(for id: String) -> URL {
        directoryURL.appendingPathComponent("\(id).json")
    }

    public func write(_ record: RunRecord) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: fileURL(for: record.id), options: .atomic)
    }

    public func loadAll() -> [RunRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> RunRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(RunRecord.self, from: data)
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func remove(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    // MARK: - Run requests (CLI → GUI delegation)

    public var requestsDirectoryURL: URL {
        directoryURL.deletingLastPathComponent().appendingPathComponent("requests", isDirectory: true)
    }

    @discardableResult
    public func prepareRequestsDirectory() -> URL {
        try? FileManager.default.createDirectory(at: requestsDirectoryURL, withIntermediateDirectories: true)
        return requestsDirectoryURL
    }

    public func writeRequest(_ payload: RunRequestPayload) throws {
        prepareRequestsDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        try data.write(to: requestsDirectoryURL.appendingPathComponent("\(payload.id).json"), options: .atomic)
    }

    public func loadRequests() -> [RunRequestPayload] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: requestsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(RunRequestPayload.self, from: $0) } }
    }

    public func removeRequest(id: String) {
        try? FileManager.default.removeItem(at: requestsDirectoryURL.appendingPathComponent("\(id).json"))
    }

    /// Deletes finished records whose last update is older than `seconds`.
    /// Running records are never pruned. `now` is injected (epoch seconds)
    /// because callers already have a timestamp and it keeps this testable.
    public func pruneFinished(olderThan seconds: Double, now: Double) {
        for record in loadAll() where record.isFinished && (now - record.updatedAt) > seconds {
            remove(id: record.id)
        }
    }

    /// Deletes records whose project file no longer exists on disk — i.e. the
    /// worktree was deleted. Called on every CLI invocation and GUI sync so
    /// stale runs never surface anywhere.
    public func pruneOrphaned() {
        for record in loadAll() where !FileManager.default.fileExists(atPath: record.projectFilePath) {
            remove(id: record.id)
        }
    }
}
