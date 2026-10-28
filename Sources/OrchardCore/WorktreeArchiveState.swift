import Foundation
import SQLite3

/// Reads only lifecycle/ownership fields, never conversation contents. Git does
/// not have an archive state: an archived Claude checkout can still exist (and
/// can subsequently be leased to a different task).
struct WorktreeArchiveState: Sendable {
    struct Session: Equatable, Sendable {
        let id: String
        let cwd: String
        let branches: Set<String>
        let archived: Bool
        let createdAt: Double
    }
    struct Evidence: Equatable, Sendable {
        let sessions: [Session]
        let matchingIDs: [String]
    }
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    struct ClaudeSession: Decodable {
        let sessionId: String
        let cwd: String
        let branch: String?
        let writtenBranches: [String]?
        let isArchived: Bool
        let createdAt: Double?
    }

    func sessions() throws -> [Session] {
        let fm = FileManager.default
        var result: [Session] = []
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        if fm.fileExists(atPath: root.path) {
            // The supported layout is account/org/local_<id>.json. Do not
            // recursively traverse conversation transcripts or linked folders.
            for account in try directories(root) {
                for organization in try directories(account) {
                    for file in try fm.contentsOfDirectory(at: organization, includingPropertiesForKeys: [.isSymbolicLinkKey])
                        where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                            throw OrchardError.message("Linked archive metadata: \(file.path)")
                        }
                        let value = try JSONDecoder().decode(ClaudeSession.self, from: Data(contentsOf: file))
                        var branches = Set(value.branch.map { [$0] } ?? [])
                        for written in value.writtenBranches ?? [] {
                            let parts = written.split(separator: "\0", omittingEmptySubsequences: false)
                            if parts.count == 2, String(parts[0]) == value.cwd { branches.insert(String(parts[1])) }
                        }
                        result.append(Session(id: "claude:" + value.sessionId, cwd: value.cwd,
                            branches: branches, archived: value.isArchived, createdAt: (value.createdAt ?? 0) / 1000))
                    }
                }
            }
        }
        let database = home.appendingPathComponent(".codex/state_5.sqlite")
        if fm.fileExists(atPath: database.path) {
            guard try database.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw OrchardError.message("Linked Codex archive database")
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }
                throw OrchardError.message("Cannot read Codex archive database")
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id,cwd,git_branch,archived,created_at FROM threads", -1, &query, nil) == SQLITE_OK else {
                throw OrchardError.message("Unsupported Codex archive schema")
            }
            defer { sqlite3_finalize(query) }
            var status = sqlite3_step(query)
            while status == SQLITE_ROW {
                func string(_ index: Int32) -> String? {
                    sqlite3_column_text(query, index).map { String(cString: $0) }
                }
                guard let id = string(0), let cwd = string(1), [0, 1].contains(sqlite3_column_int(query, 3)) else {
                    throw OrchardError.message("Invalid Codex archive metadata")
                }
                result.append(Session(id: "codex:" + id, cwd: cwd,
                    branches: Set(string(2).map { [$0] } ?? []), archived: sqlite3_column_int(query, 3) == 1,
                    createdAt: sqlite3_column_double(query, 4)))
                status = sqlite3_step(query)
            }
            guard status == SQLITE_DONE else { throw OrchardError.message("Incomplete Codex archive query") }
        }
        return result
    }

    private func directories(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter {
                let v = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard v.isSymbolicLink != true else { throw OrchardError.message("Linked archive directory") }
                return v.isDirectory == true
            }
    }

    static func deviceName(_ branch: String) -> String { branch.replacingOccurrences(of: "/", with: "-") }

    static func evidence(sessions: [Session], paths: Set<String>, name: String, boundAt: Double) -> Evidence? {
        guard !paths.isEmpty, boundAt > 0 else { return nil }
        var relevant: [Session] = []
        var matching: [String] = []
        for path in paths {
            let owners = sessions.filter { $0.cwd == path }
            let aliases = Set(owners.flatMap(\.branches).filter { deviceName($0) == name })
            // Branch names can collide after '/' -> '-'. Such legacy ownership
            // cannot identify which task owns the device without a new receipt.
            guard aliases.count == 1, let branch = aliases.first else { return nil }
            let matches = owners.filter { $0.branches.contains(branch) }
            guard !matches.isEmpty, matches.allSatisfy(\.archived) else { return nil }
            for active in owners where !active.archived {
                // A newer session may reuse the pooled path. It cannot own an
                // older branch device unless it names that branch; unknown or
                // overlapping lifetimes are deliberately preserved.
                guard active.createdAt > boundAt, !active.branches.isEmpty,
                      !active.branches.contains(where: { deviceName($0) == name }) else { return nil }
            }
            relevant.append(contentsOf: owners)
            matching.append(contentsOf: matches.map(\.id))
        }
        return Evidence(sessions: relevant.sorted { $0.id < $1.id }, matchingIDs: matching.sorted())
    }
}
