import ArgumentParser
import OrchardCore
import Foundation

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available branches, schemes, or destinations.",
        subcommands: [ListBranches.self, ListSchemes.self, ListDestinations.self]
    )
}

private let listEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    return encoder
}()

private func printJSON<T: Encodable>(_ value: T) {
    if let data = try? listEncoder.encode(value), let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

struct ListBranches: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "branches", abstract: "List discovered branches / worktrees.")

    @OptionGroup var directories: DirectoryOptions

    struct Row: Encodable {
        let branch: String
        let path: String
        let project: String
    }

    mutating func run() async throws {
        let env = CLIEnvironment(extraDirectoryPaths: directories.dir, json: directories.json)
        let worktrees = await env.worktrees()
        let rows = worktrees.map {
            Row(branch: $0.branchName, path: $0.worktreeURL.path, project: $0.project.displayName)
        }

        if directories.json {
            printJSON(rows)
        } else if rows.isEmpty {
            FileHandle.standardError.write(Data("No worktrees found. Run from an Xcode project or pass --dir.\n".utf8))
        } else {
            for row in rows {
                print("\(row.branch)\t\(row.project)\t\(row.path)")
            }
        }
    }
}

struct ListSchemes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "schemes", abstract: "List schemes for a branch.")

    @Option(name: [.short, .long], help: "Branch / worktree name (fuzzy matched).")
    var branch: String

    @OptionGroup var directories: DirectoryOptions

    mutating func run() async throws {
        let env = CLIEnvironment(extraDirectoryPaths: directories.dir, json: directories.json)
        let worktrees = await env.worktrees()

        let worktree: WorktreeContext
        switch SelectionResolver.resolveWorktree(name: branch, in: worktrees) {
        case let .success(match):
            worktree = match
        case let .failure(error):
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode(error.isAmbiguous ? 3 : 2)
        }

        let schemes = try await env.schemes(for: worktree.project)
        if directories.json {
            printJSON(schemes)
        } else {
            schemes.forEach { print($0) }
        }
    }
}

struct ListDestinations: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "destinations", abstract: "List available destinations.")

    @Flag(name: .long, help: "Only list physical devices.")
    var device = false

    @Flag(name: .long, help: "Only list simulators.")
    var simulator = false

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    struct Row: Encodable {
        let name: String
        let kind: String
        let runtime: String
        let id: String
    }

    func validate() throws {
        if device && simulator {
            throw ValidationError("Pass only one of --device or --simulator.")
        }
    }

    mutating func run() async throws {
        let env = CLIEnvironment(extraDirectoryPaths: [], json: json)
        let kindFilter = destinationKindFilter(device: device, simulator: simulator)
        var destinations = try await env.destinations()
        if let kindFilter {
            destinations = destinations.filter { $0.kind == kindFilter }
        }

        let rows = destinations.map {
            Row(name: $0.name, kind: $0.kind.rawValue, runtime: $0.runtime, id: $0.id)
        }

        if json {
            printJSON(rows)
        } else {
            for row in rows {
                print("\(row.name)\t\(row.kind)\t\(row.runtime)\t\(row.id)")
            }
        }
    }
}

private extension SelectionError {
    var isAmbiguous: Bool {
        if case .ambiguous = self { return true }
        return false
    }
}
