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

- `Sources/DevRunnerApp/DevRunnerApp.swift`
  - App entry point and `MenuBarExtra`.
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
