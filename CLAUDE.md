# Orchard — Internal Notes

User-facing documentation lives in `README.md` (English) and `README.ja.md` (Japanese). This file holds internal behavior details and guidance for coding agents.

Orchard is intentionally repository-agnostic: users configure directories to scan, and Orchard discovers Xcode projects and git worktrees inside those directories. Do not add assumptions tied to any specific repository.

## Current Product Behavior

- Runs as a `MenuBarExtra` app.
- Lets users configure scan directories from the settings view.
- Discovers git repositories and worktrees under configured directories.
- Lets users choose:
  - Project: shown as git branch name.
  - Scheme: loaded from `xcodebuild -list -json`.
  - Destination: physical devices plus favorite simulators by default.
- Simulator destinations can be expanded with `Show More Simulators` inside the Destination menu.
- Simulator favorites are stored in `UserDefaults`.
- Project/scheme/destination are presented as a single grouped "form card" of menu rows (icon + label + value + chevron), with a prominent full-width `Build & Run` button below it.
- `Build & Run` builds, installs, and launches the selected scheme.
- Multiple jobs can be shown in the Runs section.
- Jobs for the same project (worktree) are grouped: collapsed groups render as a z-stacked pile of cards with a `square.stack` count badge. Tapping the pile (or the badge) expands the group into a row of cards; the badge or the trailing `chevron.compact.left` collapse button folds it again. The front card of a collapsed pile is the selected job in that group, falling back to the most recent one.
- Job cards layer an opaque `windowBackgroundColor` base under their tint, and dimmed back cards in a pile are dimmed with an opaque overlay (not `.opacity`), so stacked card content never bleeds through in the vibrant menu bar window.
- A global keyboard shortcut can be recorded in Settings. Pressing it from any app opens/toggles the Orchard menu bar window. It is registered with Carbon `RegisterEventHotKey` (no accessibility permission needed) and stored in `UserDefaults` (`globalHotKey`).
- Only one job is kept for each destination. Starting another job for the same destination stops/removes the previous one.
- Each run item owns its own `Stop`, `Rerun`, and `Close` buttons.
- The selected run item controls the displayed console log.
- The log view is intended to show app console output, not Orchard's own build/install command output.
- Orchard's own diagnostics live in a separate Console screen, opened with the `terminal` icon left of the gear icon. It shows timestamped job lifecycle events (start/stop/fail with error messages) and the raw build/install command output (`xcodebuild`, `simctl`, `devicectl`), kept in memory (`appLogText`, capped at 200k chars) with its own search/copy/clear.

## Run State UI

Each job item has a fixed-height status row.

- While build/install work is in progress, it shows a spinner and text such as `Building`, `Resolving build product`, `Booting simulator`, or `Installing`.
- Once the app has launched and Orchard is only attached to console output, the progress row no longer shows a spinner.
- A launched app still counts as a running job because `Stop` should terminate it like Xcode's Stop button.
- In that state the UI shows `checkmark.circle + Succeeded`.
- Stopped jobs show `stop.circle + Stopped`.
- Failed jobs show `xmark.circle + Failed`.

## Build And Run Details

Builds are handled by `BuildRunService`.

- Build:
  - `xcodebuild <project args> -scheme <scheme> -destination <destination> build`
  - Orchard intentionally does not pass `-derivedDataPath`.
  - This lets `xcodebuild` use the standard Xcode DerivedData location, so it can share cache behavior with normal Xcode builds.
- Build product lookup:
  - `xcodebuild ... -showBuildSettings -json`
  - `XcodeBuildSettings.firstRunnableApp` finds the first `.app` with a bundle identifier.
- Simulator install/launch:
  - `xcrun simctl boot <udid>`
  - `xcrun simctl install <udid> <app>`
  - `xcrun simctl launch --terminate-running-process --console <udid> <bundle id>`
- Device install/launch:
  - `xcrun devicectl device --quiet install app --device <id> <app>`
  - `xcrun devicectl device --quiet process launch --device <id> --terminate-existing --console <bundle id>`
- Stop:
  - Always terminates the launched app, not only the local build process.
  - Simulator stop uses `simctl terminate`.
  - Device stop resolves the installed app URL and running process IDs through `devicectl device info apps/processes`, then terminates matching processes.

`--console` keeps the launch process attached after the app starts. This is why the job can remain `running` after the build is already done.

## CLI Internals

See `README.md` for the user-facing CLI reference. Internal details:

- By default `run` runs attached: the CLI resolves the worktree/scheme/destination, builds and launches in-process, streams the app's console to stdout, and blocks until the app exits. The logs are also recorded to the shared run store, so the Orchard app sees this run and can show its logs, rerun it, or stop it. Meant to be launched as a background task (the agent isn't blocked, but the launched app's lifetime is tied to the CLI process).
- `--delegate` hands the run to the Orchard app: the CLI writes a request, makes sure the app is running, and returns immediately. The GUI then builds/launches the run in-process, holds the console, records the logs, and shows it in the Runs list — the launched app's lifetime is tied to the long-running GUI. Exit code reflects delegation (`0` delegated, `2` not found, `3` ambiguous).
- Exit code `0` also covers a stop initiated from the GUI (stop / rerun / supersede send `SIGTERM`; the run tears the app down and exits cleanly as `stopped`, so a background task doesn't see it as a crash).
- Runs are shared both ways through the run store (`~/Library/Application Support/Orchard/runs/<id>.json`):
  - **CLI → GUI**: each `run` writes/updates a `RunRecord` (source `cli`) as it progresses; the menu bar app watches the store with FSEvents (only while the menu is open — no idle polling) and mirrors CLI runs into its Runs list. The CLI stays terminal-complete, so `run` works whether or not the GUI is open. A CLI run records its PID, so the GUI's Stop button signals it (SIGINT); the CLI then tears down the app, writes `stopped`, and exits 130. Rerun from the GUI cancels the CLI run and restarts it as a GUI-managed run.
  - **GUI → CLI**: GUI runs (including reruns) also write records (source `gui`), so an agent can read them with `orchard runs` / `orchard runs <id> --log`.
- One run per destination: starting a run (CLI or GUI) on a destination replaces any existing run there. Jobs whose worktree/branch was deleted from disk are dropped when the menu opens or refreshes. Finished records are pruned after 24h.
- Directory precedence for worktree discovery: `--dir` overrides the `ORCHARD_DIRS` env var (colon-separated), which overrides the directories the GUI persisted. The CLI reads the GUI's settings via `UserDefaults(suiteName: "dev.codex.Orchard")` — necessary because a bare binary has no bundle id, so `UserDefaults.standard` would resolve to a different domain than the bundled GUI. Run via the bundle or rely on `--dir`/`ORCHARD_DIRS` if the shared defaults are unavailable.

## Discovery Model

Worktree discovery is independent of any terminal app.

Main flow:

1. User configures one or more scan directories.
2. `WorktreeContextResolver.resolve(fromConfiguredDirectoryURLs:)` walks configured directories.
3. It finds git repositories.
4. For each repository, it runs `git worktree list --porcelain`.
5. It creates one `WorktreeContext` per worktree.
6. It walks up from each worktree to find the nearest `.xcworkspace` or `.xcodeproj`.

Fallback scanning also checks:

- `.worktrees`
- `.claude/worktrees`

Terminal integration code still exists (`TerminalContextProvider`, `GhosttyContextProvider`), but the current user-facing flow does not depend on Ghostty.

## Source Map

- `Sources/OrchardApp/main.swift`
  - Process entry point. Dispatches to the GUI (no args) or the headless CLI (subcommand given).
- `Sources/OrchardApp/OrchardApp.swift`
  - `MenuBarExtra` app definition (no longer `@main`; launched from `main.swift`).
- `Sources/OrchardApp/CLI/`
  - `OrchardCLI.swift`: root command, shared `--dir`/`--json` options, concrete-type dispatch (`runOrchardCLI`).
  - `RunCommand.swift`: `run` subcommand and exit-code mapping.
  - `ListCommand.swift`: `list branches|schemes|destinations`.
  - `CLIEnvironment.swift`: directory resolution, fetching, build-log wiring, Ctrl-C/timeout handling, NDJSON events.
- `Sources/OrchardApp/RunnerMenuView.swift`
  - Menu bar UI.
  - Project/scheme/destination controls.
  - Destination menu, simulator favorite/show more UI.
  - Runs section, per-job action buttons, status rows, log view.
- `Sources/OrchardApp/RunnerViewModel.swift`
  - UI state and orchestration.
  - Stores scan directories, simulator favorites, and the global hot key in `UserDefaults`.
  - Starts/stops/reruns/closes jobs.
  - Groups jobs by project (`jobGroups`) for the stacked Runs UI.
  - Enforces one job per destination.
- `Sources/OrchardApp/GlobalHotKey.swift`
  - `GlobalHotKey` model (key code, Carbon modifiers, display string).
  - `GlobalHotKeyManager` wrapping Carbon `RegisterEventHotKey`.
  - `MenuBarWindowPresenter`, which opens the `MenuBarExtra` window by clicking the status item button (KVC on `NSStatusBarWindow`, since there is no public API).
- `Sources/OrchardApp/ShortcutRecorderField.swift`
  - Settings control that records a shortcut via a local `keyDown` event monitor. Esc cancels; a cmd/opt/ctrl modifier is required.
- `Sources/OrchardCore/WorktreeContext.swift`
  - Worktree and configured-directory discovery.
- `Sources/OrchardCore/ProjectDetector.swift`
  - Finds `.xcworkspace` or `.xcodeproj`.
- `Sources/OrchardCore/GitService.swift`
  - Git root/branch/worktree calls.
- `Sources/OrchardCore/XcodeService.swift`
  - Schemes, destinations, build settings.
- `Sources/OrchardCore/BuildRunService.swift`
  - Build/install/launch/stop implementation.
- `Sources/OrchardCore/XcodeModels.swift`
  - Shared model types.
- `Sources/OrchardCore/SelectionResolver.swift`
  - Resolves human-readable branch/scheme/destination names to model objects (staged fuzzy matching). Shared by the CLI.
- `Sources/OrchardCore/AppConfiguration.swift`
  - UserDefaults suite name and key constants shared by the GUI and CLI.
- `Sources/OrchardCore/RunRecord.swift` / `RunStore.swift`
  - Serializable run snapshot and the shared on-disk store (`Application Support/Orchard/runs/`) the CLI writes and the GUI polls, so CLI runs show in the Runs list.
- `Scripts/package-app.sh`
  - Builds and packages `Orchard.app`.

## Development Commands

Run tests:

```bash
swift test
```

Build app bundle:

```bash
Scripts/package-app.sh
```

Open packaged app:

```bash
open Orchard.app
```

Restart the currently running app:

```bash
kill $(pgrep -f '/Orchard.app/Contents/MacOS/orchard')
open Orchard.app
```

## Notes For Future Agents

- Keep Orchard generic. Do not add repository-specific assumptions.
- Prefer configured directory scanning over terminal/window introspection.
- Do not put build/install command output in the Log view unless the product direction changes. The Log view is for app console output.
- Be careful with job status:
  - `running` currently means the app is launched or Orchard is still attached to console output.
  - Build progress is represented by non-empty `activityText`.
  - Empty `activityText` with a running job means the app launched successfully and progress UI should be hidden.
- If changing build performance behavior, remember that omitting `-derivedDataPath` is intentional to share standard Xcode DerivedData.
- After UI changes, run `swift test`, then `Scripts/package-app.sh`, then restart `Orchard.app`.
