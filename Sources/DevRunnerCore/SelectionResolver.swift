import Foundation

/// Error describing why a human-readable name could not be resolved to a
/// single worktree / scheme / destination. Carries the candidate list so the
/// CLI can surface actionable choices (and pick a distinct exit code).
public enum SelectionError: Error, CustomStringConvertible {
    case notFound(kind: String, query: String, available: [String])
    case ambiguous(kind: String, query: String, candidates: [String])

    public var description: String {
        switch self {
        case let .notFound(kind, query, available):
            let list = available.isEmpty ? "  (none available)" : available.map { "  - \($0)" }.joined(separator: "\n")
            return "No \(kind) matches \"\(query)\".\nAvailable \(kind)s:\n\(list)"
        case let .ambiguous(kind, query, candidates):
            let list = candidates.map { "  - \($0)" }.joined(separator: "\n")
            return "\"\(query)\" is ambiguous and matches multiple \(kind)s:\n\(list)"
        }
    }
}

/// Resolves the human-readable names an agent or user would type (a branch
/// name, a scheme name, a simulator name) into the concrete model objects the
/// build pipeline needs. Pure functions over already-fetched lists so they are
/// trivially testable and reusable from both the CLI and the GUI.
public enum SelectionResolver {
    public static func resolveWorktree(
        name: String,
        in worktrees: [WorktreeContext]
    ) -> Result<WorktreeContext, SelectionError> {
        resolve(
            query: name,
            kind: "branch",
            items: worktrees,
            keys: { [$0.branchName, $0.worktreeURL.lastPathComponent, $0.worktreeURL.path] },
            describe: { "\($0.branchName) → \($0.worktreeURL.path)" }
        )
    }

    public static func resolveScheme(
        name: String,
        in schemes: [String]
    ) -> Result<String, SelectionError> {
        resolve(
            query: name,
            kind: "scheme",
            items: schemes,
            keys: { [$0] },
            describe: { $0 }
        )
    }

    public static func resolveDestination(
        name: String,
        kind kindFilter: XcodeDestination.Kind?,
        in destinations: [XcodeDestination]
    ) -> Result<XcodeDestination, SelectionError> {
        let candidates = kindFilter.map { kind in destinations.filter { $0.kind == kind } } ?? destinations

        // A UDID is unambiguous by construction — accept an exact id match
        // before falling back to fuzzy name matching.
        if let exact = candidates.first(where: { $0.id == name }) {
            return .success(exact)
        }

        return resolve(
            query: name,
            kind: "destination",
            items: candidates,
            keys: { [$0.name, $0.displayName] },
            describe: { $0.displayName }
        )
    }

    /// Staged matching shared by all resolvers: exact → case-insensitive →
    /// prefix → substring. The first stage that yields any match decides the
    /// outcome (one → success, many → ambiguous). This lets a tighter stage
    /// disambiguate before a looser one is ever considered.
    private static func resolve<T>(
        query: String,
        kind: String,
        items: [T],
        keys: (T) -> [String],
        describe: (T) -> String
    ) -> Result<T, SelectionError> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        func indices(where predicate: (String) -> Bool) -> [Int] {
            items.indices.filter { keys(items[$0]).contains(where: predicate) }
        }

        let stages: [[Int]] = [
            indices { $0 == trimmed },
            indices { $0.lowercased() == lowered },
            indices { $0.lowercased().hasPrefix(lowered) },
            indices { $0.lowercased().contains(lowered) }
        ]

        for stage in stages {
            let unique = Array(Set(stage)).sorted()
            if unique.count == 1 {
                return .success(items[unique[0]])
            }
            if unique.count > 1 {
                return .failure(.ambiguous(
                    kind: kind,
                    query: trimmed,
                    candidates: unique.map { describe(items[$0]) }
                ))
            }
        }

        return .failure(.notFound(kind: kind, query: trimmed, available: items.map(describe)))
    }
}
