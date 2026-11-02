import Foundation

/// File-based store for `RunRecord`s. Each run is one `<id>.json` file under
/// `~/Library/Application Support/Orchard/runs/`, written by the process that
/// owns the run and read by `orchard runs` / `orchard stop` from any shell.
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

    /// Marks `running` records whose owning process is gone as `stopped`, so a
    /// run whose process crashed or was killed does not look alive forever.
    public func finishAbandoned(isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        for var record in loadAll() where record.status == .running && !(record.pid.map(isAlive) ?? false) {
            record.status = .stopped
            record.activityText = "Owning process exited"
            try? write(record)
        }
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
    /// worktree was deleted, so stale runs never surface anywhere.
    public func pruneOrphaned() {
        for record in loadAll() where !FileManager.default.fileExists(atPath: record.projectFilePath) {
            remove(id: record.id)
        }
    }
}
