import ArgumentParser
import OrchardCore
import Foundation

/// Lets an agent read every run — GUI- or CLI-originated — from the shared run
/// store: list them, or print one run's log. This is how runs started or rerun
/// from the GUI become observable on the command line.
struct RunsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runs",
        abstract: "List runs (GUI and CLI), or print one run's log."
    )

    @Argument(help: "Run id (or unique prefix) to show in detail. Omit to list all runs.")
    var id: String?

    @Flag(name: .long, help: "Print only the selected run's log (requires an id).")
    var log = false

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() async throws {
        RunStore.shared.pruneOrphaned()
        let records = RunStore.shared.loadAll().sorted { $0.startedAt > $1.startedAt }

        if let id {
            guard let record = records.first(where: { $0.id == id || $0.id.hasPrefix(id) }) else {
                FileHandle.standardError.write(Data("No run matches \"\(id)\".\n".utf8))
                throw ExitCode(2)
            }

            if log {
                print(record.log, terminator: "")
            } else if json {
                printJSON(record)
            } else {
                printDetail(record)
            }
            return
        }

        if json {
            printJSON(records.map(RunSummary.init))
        } else if records.isEmpty {
            FileHandle.standardError.write(Data("No runs recorded.\n".utf8))
        } else {
            for record in records {
                let shortID = String(record.id.prefix(8))
                print("\(shortID)\t\(record.source)\t\(record.status.rawValue)\t\(record.branchName)\t\(record.scheme)\t\(record.destination.name)")
            }
        }
    }

    private func printDetail(_ record: RunRecord) {
        let lines = [
            "id:          \(record.id)",
            "source:      \(record.source)",
            "status:      \(record.status.rawValue)",
            "branch:      \(record.branchName)",
            "scheme:      \(record.scheme)",
            "destination: \(record.destination.name) (\(record.destination.kind), \(record.destination.runtime))",
            "activity:    \(record.activityText)"
        ]
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n--- log ---\n").utf8))
        print(record.log, terminator: "")
    }

    /// Flattened summary for JSON listing (one line per run).
    private struct RunSummary: Encodable {
        let id: String
        let source: String
        let status: String
        let branch: String
        let scheme: String
        let destination: String
        let kind: String
        let startedAt: Double
        let updatedAt: Double

        init(_ record: RunRecord) {
            id = record.id
            source = record.source
            status = record.status.rawValue
            branch = record.branchName
            scheme = record.scheme
            destination = record.destination.name
            kind = record.destination.kind
            startedAt = record.startedAt
            updatedAt = record.updatedAt
        }
    }

    private func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}
