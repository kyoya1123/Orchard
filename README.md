# DevRunner

DevRunner is a macOS menu bar app for developers who want to build and run Xcode schemes without opening Xcode just to choose a scheme or destination.

The app is intentionally repository-agnostic. It is not tied to `cir-mobile`; users configure directories to scan, and DevRunner discovers Xcode projects and git worktrees inside those directories.

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
- A global keyboard shortcut can be recorded in Settings. Pressing it from any app opens/toggles the DevRunner menu bar window. It is registered with Carbon `RegisterEventHotKey` (no accessibility permission needed) and stored in `UserDefaults` (`globalHotKey`).
- Only one job is kept for each destination. Starting another job for the same destination stops/removes the previous one.
- Each run item owns its own `Stop`, `Rerun`, and `Close` buttons.
- The selected run item controls the displayed console log.
- The log view is intended to show app console output, not DevRunner's own build/install command output.
- DevRunner's own diagnostics live in a separate Console screen, opened with the `terminal` icon left of the gear icon. It shows timestamped job lifecycle events (start/stop/fail with error messages) and the raw build/install command output (`xcodebuild`, `simctl`, `devicectl`), kept in memory (`appLogText`, capped at 200k chars) with its own search/copy/clear.

## Run State UI

Each job item has a fixed-height status row.

- While build/install work is in progress, it shows a spinner and text such as `Building`, `Resolving build product`, `Booting simulator`, or `Installing`.
- Once the app has launched and DevRunner is only attached to console output, the progress row no longer shows a spinner.
- A launched app still counts as a running job because `Stop` should terminate it like Xcode's Stop button.
- In that state the UI shows `checkmark.circle + Succeeded`.
- Stopped jobs show `stop.circle + Stopped`.
- Failed jobs show `xmark.circle + Failed`.

## Build And Run Details

Builds are handled by `BuildRunService`.

- Build:
  - `xcodebuild <project args> -scheme <scheme> -destination <destination> build`
  - DevRunner intentionally does not pass `-derivedDataPath`.
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

## CLI

The same `dev-runner` binary is also a headless CLI: pass a subcommand and it
runs the build/launch pipeline without starting the menu bar GUI. With no
arguments it launches the GUI as before. This lets an agent drive a run from
the terminal — "build this branch with ProdDebug on iPhone 15" — using the same
`BuildRunService` the UI uses.

```bash
# Build + install + launch (blocks until the launched app exits)
dev-runner run --branch <branch> --scheme <scheme> --destination <name-or-udid> \
  [--device | --simulator] [--follow] [--timeout <seconds>] [--dir <path> ...] [--json]

# Discovery
dev-runner list branches [--dir <path> ...] [--json]
dev-runner list schemes --branch <branch> [--dir <path> ...] [--json]
dev-runner list destinations [--device | --simulator] [--json]

# Observe runs (GUI- and CLI-originated)
dev-runner runs [--json]                # list every recorded run
dev-runner runs <id> [--json]           # show one run's detail + log
dev-runner runs <id> --log              # print only that run's log
```

Branch, scheme, and destination are fuzzy matched (exact → case-insensitive →
prefix → substring); a destination UDID matches exactly. Ambiguous input lists
the candidates so you can narrow it (e.g. pass a worktree path fragment or a
UDID).

By default `run` **delegates to the DevRunner app**: it resolves the
worktree/scheme/destination, writes a request, makes sure the app is running,
and returns immediately. The GUI then builds/launches the run in-process,
holds the console, records the logs, and shows it in the Runs list — so an
agent isn't left monitoring, the launched app's lifetime is tied to the
long-running GUI (not to the CLI), and the logs are always visible in the GUI
(and via `dev-runner runs <id> --log`). Exit code reflects delegation
(`0` delegated, `2` not found, `3` ambiguous).

Pass `--follow` to instead run attached in the terminal: the CLI builds and
launches, streams the app's console to stdout, and blocks until the app exits
(logs are also recorded for the GUI). Use it when you want to watch the logs
live.

Output and exit codes (designed for agents):

- Build/tool command lines and progress go to **stderr**; the launched app's
  console output goes to **stdout**.
- `--json` emits NDJSON events on stdout: `{"type":"progress"|"command"|"console"|"result"|"error", ...}`.
- Exit codes: `0` success, `2` not found, `3` ambiguous, `4` build/launch
  failed, `130` interrupted (Ctrl-C, which also terminates the launched app).

Runs are shared both ways through a run store
(`~/Library/Application Support/DevRunner/runs/<id>.json`), so the GUI and the
CLI see each other's runs:

- **CLI → GUI**: each `run` writes/updates a `RunRecord` (source `cli`) as it
  progresses; the menu bar app watches the store with FSEvents (only while the
  menu is open — no idle polling) and mirrors CLI runs into its Runs list. The
  CLI stays terminal-complete, so `run` works whether or not the GUI is open.
  A CLI run records its PID, so the GUI's Stop button signals it (SIGINT); the
  CLI then tears down the app, writes `stopped`, and exits 130. Rerun from the
  GUI cancels the CLI run and restarts it as a GUI-managed run.
- **GUI → CLI**: GUI runs (including reruns) also write records (source `gui`),
  so an agent can read them with `dev-runner runs` / `dev-runner runs <id> --log`.

One run per destination: starting a run (CLI or GUI) on a destination replaces
any existing run there. Jobs whose worktree/branch was deleted from disk are
dropped when the menu opens or refreshes. Finished records are pruned after 24h.

Directory precedence for worktree discovery: `--dir` overrides the
`DEVRUNNER_DIRS` env var (colon-separated), which overrides the directories the
GUI persisted. The CLI reads the GUI's settings via
`UserDefaults(suiteName: "dev.codex.DevRunner")` — necessary because a bare
binary has no bundle id, so `UserDefaults.standard` would resolve to a different
domain than the bundled GUI. Run via the bundle or rely on `--dir`/`DEVRUNNER_DIRS`
if the shared defaults are unavailable.

After `Scripts/package-app.sh`, symlink the binary onto your PATH:

```bash
ln -sf /Users/kyoya/Projects/DevRunner/DevRunner.app/Contents/MacOS/dev-runner /usr/local/bin/dev-runner
```

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

- `Sources/DevRunnerApp/main.swift`
  - Process entry point. Dispatches to the GUI (no args) or the headless CLI (subcommand given).
- `Sources/DevRunnerApp/DevRunnerApp.swift`
  - `MenuBarExtra` app definition (no longer `@main`; launched from `main.swift`).
- `Sources/DevRunnerApp/CLI/`
  - `DevRunnerCLI.swift`: root command, shared `--dir`/`--json` options, concrete-type dispatch (`runDevRunnerCLI`).
  - `RunCommand.swift`: `run` subcommand and exit-code mapping.
  - `ListCommand.swift`: `list branches|schemes|destinations`.
  - `CLIEnvironment.swift`: directory resolution, fetching, build-log wiring, Ctrl-C/timeout handling, NDJSON events.
- `Sources/DevRunnerApp/RunnerMenuView.swift`
  - Menu bar UI.
  - Project/scheme/destination controls.
  - Destination menu, simulator favorite/show more UI.
  - Runs section, per-job action buttons, status rows, log view.
- `Sources/DevRunnerApp/RunnerViewModel.swift`
  - UI state and orchestration.
  - Stores scan directories, simulator favorites, and the global hot key in `UserDefaults`.
  - Starts/stops/reruns/closes jobs.
  - Groups jobs by project (`jobGroups`) for the stacked Runs UI.
  - Enforces one job per destination.
- `Sources/DevRunnerApp/GlobalHotKey.swift`
  - `GlobalHotKey` model (key code, Carbon modifiers, display string).
  - `GlobalHotKeyManager` wrapping Carbon `RegisterEventHotKey`.
  - `MenuBarWindowPresenter`, which opens the `MenuBarExtra` window by clicking the status item button (KVC on `NSStatusBarWindow`, since there is no public API).
- `Sources/DevRunnerApp/ShortcutRecorderField.swift`
  - Settings control that records a shortcut via a local `keyDown` event monitor. Esc cancels; a cmd/opt/ctrl modifier is required.
- `Sources/DevRunnerCore/WorktreeContext.swift`
  - Worktree and configured-directory discovery.
- `Sources/DevRunnerCore/ProjectDetector.swift`
  - Finds `.xcworkspace` or `.xcodeproj`.
- `Sources/DevRunnerCore/GitService.swift`
  - Git root/branch/worktree calls.
- `Sources/DevRunnerCore/XcodeService.swift`
  - Schemes, destinations, build settings.
- `Sources/DevRunnerCore/BuildRunService.swift`
  - Build/install/launch/stop implementation.
- `Sources/DevRunnerCore/XcodeModels.swift`
  - Shared model types.
- `Sources/DevRunnerCore/SelectionResolver.swift`
  - Resolves human-readable branch/scheme/destination names to model objects (staged fuzzy matching). Shared by the CLI.
- `Sources/DevRunnerCore/AppConfiguration.swift`
  - UserDefaults suite name and key constants shared by the GUI and CLI.
- `Sources/DevRunnerCore/RunRecord.swift` / `RunStore.swift`
  - Serializable run snapshot and the shared on-disk store (`Application Support/DevRunner/runs/`) the CLI writes and the GUI polls, so CLI runs show in the Runs list.
- `Scripts/package-app.sh`
  - Builds and packages `DevRunner.app`.

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
open /Users/kyoya/Projects/DevRunner/DevRunner.app
```

Restart the currently running app:

```bash
kill $(pgrep -f '/DevRunner.app/Contents/MacOS/dev-runner')
open /Users/kyoya/Projects/DevRunner/DevRunner.app
```

## Repository State

The app lives at:

```text
/Users/kyoya/Projects/DevRunner
```

It is a standalone git repository.

Recent commits:

- `59b8c73 Initial DevRunner app`
- `a2ec7f8 Improve run job tabs and console logging`
- `9e42356 Refine run controls and destination selection`

## Notes For Future Agents

- Keep DevRunner generic. Do not add `cir-mobile`-specific assumptions.
- Prefer configured directory scanning over terminal/window introspection.
- Do not put build/install command output in the Log view unless the product direction changes. The Log view is for app console output.
- Be careful with job status:
  - `running` currently means the app is launched or DevRunner is still attached to console output.
  - Build progress is represented by non-empty `activityText`.
  - Empty `activityText` with a running job means the app launched successfully and progress UI should be hidden.
- If changing build performance behavior, remember that omitting `-derivedDataPath` is intentional to share standard Xcode DerivedData.
- After UI changes, run `swift test`, then `Scripts/package-app.sh`, then restart `DevRunner.app`.
