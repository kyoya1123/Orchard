# DevRunner

Developer-oriented menu bar runner for Xcode projects.

Current scope:

- Lets you configure directories to scan from inside the app.
- Resolves git repositories inside configured directories.
- Uses `git worktree list --porcelain` to discover all worktrees for each configured repository.
- Also scans `.worktrees` and `.claude/worktrees` as a fallback.
- Walks up from each discovered worktree to find the nearest `.xcworkspace` or `.xcodeproj`.
- Lets you choose which detected worktree/project to run.
- Loads schemes with `xcodebuild -list -json`.
- Loads available iOS Simulator destinations with `xcrun simctl list devices available --json`.
- Builds, installs, and launches the selected scheme on the selected simulator.

## Run

```bash
cd ~/Projects/DevRunner
swift run dev-runner
```

For the app bundle:

```bash
cd ~/Projects/DevRunner
Scripts/package-app.sh
open DevRunner.app
```

The first Ghostty refresh can trigger macOS Automation permission prompts because the app uses Ghostty AppleScript support.

## Architecture

Worktree discovery is independent of any terminal app. Configure repository or parent directories in the app's Scan Directories section.

Terminal integration is still isolated behind `TerminalContextProvider` for future optional features, but it is no longer required for worktree discovery.

- `GhosttyContextProvider` is the only provider today.
- Add Terminal.app, iTerm2, VS Code, Cursor, or Finder support by adding another provider and registering it in `TerminalContextProviderRegistry`.
- Xcode detection and execution are independent of the terminal provider.

## Distribution Notes

This SwiftPM executable is the MVP shape. A distributable menu bar app should wrap the same `DevRunnerCore` module in a signed and notarized `.app` bundle with `LSUIElement` enabled.
