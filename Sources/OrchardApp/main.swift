import ArgumentParser
import OrchardCore
import Foundation

// Single binary, two personalities:
//   `orchard`            → launch the menu bar GUI (unchanged behaviour)
//   `orchard run ...`    → headless CLI, never touches AppKit
// The dispatch happens before any SwiftUI/AppKit type is referenced so the CLI
// path stays a pure command-line tool.
let cliArguments = Array(CommandLine.arguments.dropFirst())
let cliSubcommands: Set<String> = ["run", "list", "runs", "simulator", "cleanup", "cleanup-worker", "help"]

// Only treat the launch as CLI when the first token is a known subcommand or a
// help flag. A GUI launch (Finder, LaunchServices, login item) can pass macOS
// internal arguments (-psn_…, -NSDocumentRevisionsDebugMode, -AppleLanguages,
// …); those must fall through to the GUI rather than abort as a CLI parse error.
if let first = cliArguments.first,
   cliSubcommands.contains(first) || first == "-h" || first == "--help" {
    await runOrchardCLI(cliArguments)
} else {
    OrchardApp.main()
}
