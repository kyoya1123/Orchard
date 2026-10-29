# Orchard

**English** | [日本語](README.ja.md)

Orchard is a macOS menu bar app (and headless CLI) for building and running Xcode apps on simulators and devices — without opening Xcode just to pick a scheme or destination.

It is built with git worktree workflows in mind: use a project from the CLI and its repository is added automatically, so every worktree shows up as a selectable project, labeled by its branch name. Pick a project, a scheme, and a destination, then hit **Build & Run**.

## Features

- **Menu bar UI** — choose project (git branch) / scheme / destination from a compact form, with a one-click **Build & Run** button.
- **Worktree discovery** — discovers CLI-registered repositories and optionally configured directories through `git worktree list`, then finds the nearest `.xcworkspace` / `.xcodeproj` for each. Run multiple branches side by side without switching anything.
- **Simulators and devices** — physical devices and your favorite simulators are listed by default; more simulators are one click away. Favorites are remembered.
- **Run management** — each run has its own console log, **Stop** / **Rerun** / **Close** controls, and status. Runs are grouped per project, and starting a new run on a destination replaces the previous one — just like Xcode's Run button.
- **App console, not build noise** — the log view shows the launched app's console output. Orchard's own build/install diagnostics live in a separate Console screen.
- **Global hotkey** — record a shortcut in Settings and toggle the Orchard window from any app (no accessibility permission required).
- **Shares Xcode's build cache** — builds run through `xcodebuild` with the standard DerivedData location, so Orchard and Xcode reuse each other's build artifacts.
- **Headless CLI for automation** — the same binary doubles as an `orchard` CLI that drives the exact same build/install/launch pipeline, with fuzzy matching, NDJSON output, and a shared run store so the GUI and CLI see each other's runs. Designed to be driven by coding agents.

## Swift package disk usage

Orchard reuses the project's existing `DerivedData/SourcePackages` when present. For new worktrees it keeps a private package directory under `~/Library/Caches/Orchard/SourcePackages-v1/`, seeded from an APFS copy-on-write template. Templates are keyed by Git repository, `Package.resolved` and the selected Xcode; at most three templates per repository are retained. Source changes remain private to each worktree.

Scheme listing, builds and build-product lookup use the same package directory. Commands for the same project are serialized across the GUI and CLI until build-product lookup finishes; different worktrees can still build concurrently. The normal DerivedData build location remains unchanged. A successful resolution/build publishes a template only when the pinned Git checkouts are clean and artifact paths are self-contained. Local/registry packages and unsupported lockfile formats use normal Xcode behavior. Failed clones fall back to Xcode resolution, never a full copy.

This reduces growth from new worktrees; it does not shrink existing Build products or Simulator data. The SPM sharing service does not delete per-worktree checkouts while building. Managed caches record their owner and pinned dependency revisions. The separate collector below can reclaim a cache only after its recorded worktree disappears and its pinned checkouts remain unchanged. Legacy entries without a receipt, live-worktree caches, templates and manual dependency edits remain protected. To opt out, launch Orchard/its CLI with `ORCHARD_SPM_CACHE=0`. After stopping builds, immutable `templates/` subdirectories can be removed to reclaim unused snapshots; private `worktrees/` directories may contain edits and require manual review before removal.

## Empty Simulator bases

`orchard run --branch <branch> --scheme <scheme> --branch-simulator` prepares a branch Simulator automatically. Orchard checks the selected Xcode's installed, available iOS runtimes on each request, chooses the newest compatible iPhone hardware generation (preferring Pro within a generation), and reuses an exact matching branch Simulator or clones a base with `simctl clone`. It does not download runtimes. Explicit `--device-type` and `--runtime` values override automatic selection. Existing `--destination` runs are unchanged.

A base is created, booted through `simctl bootstatus`, checked for system apps only, then shut down. Orchard installs no app and applies no app settings to it. Bases are stored in a separate CoreSimulator device set under `~/Library/Application Support/Orchard/SimulatorBases-v1/devices`, so they do not appear among normal run destinations. The registry includes the device type, runtime build, Xcode build/tool path and initialization revision. Matching bases are reused; changes prepare a new base on demand, not a new base for every build.

After preparation (and cloning, when requested) succeeds, obsolete registered bases are deleted only if still shut down, unmodified in identity, and free of user-installed apps. Busy/modified bases are preserved with a diagnostic and retried later. Failed initialization/cloning retains the previous base. Branch Simulators, their app data, and unmanaged devices—including a legacy device named `base`—are never deleted by this feature. Cross-process locking prevents duplicate initialization. APFS sharing reduces growth of new Simulators; it does not compact existing ones or prevent new logs/app data from accumulating.

```bash
# Prepare/refresh only the base; no app build or installation
orchard simulator base --json

# Reuse/create one named branch Simulator; stdout is its UDID
orchard simulator ensure --name feature-example

# Explicit test configuration
orchard simulator ensure --name feature-example \
  --device-type "iPhone 18 Pro" --runtime "iOS 27.0"

# Build/run using automatic latest-device selection
orchard run --branch feature/example --scheme MyScheme --branch-simulator --delegate
```

`Scripts/ios-run.sh` is the compatible skill adapter (`[branch-or-device] [scheme] [device-type] [iOS] [delegate|follow]`). Replace an older skill's `run.sh` with this adapter once; base management subsequently ships in Orchard itself. Omitted device/runtime arguments select `latest`; repository instructions that pin an older configuration must be updated separately to opt into automatic selection.

## Background artifact cleanup

Orchard checks positively associated worktree devices at app startup/reopen, on GUI runs, and on each `run`, `list`, `runs`, or `simulator` CLI invocation. Help and cleanup previews never schedule deletion. Automatic checks use only the `orphaned-devices` scope and existing ownership records, in a coalesced background worker with bounded lock/retry waits. Failed requests remain pending for the next invocation.

A device qualifies only when **every associated worktree path is confirmed missing**. Existing worktrees are preserved regardless of age, branch merge status or Claude/Codex archive state. Unknown ownership, inaccessible paths, broken links, renamed devices and ambiguous device identity are preserved. No session databases, conversation files or process listings are read for device cleanup. iOS ownership comes from Orchard's recorded UDID/project association; Android uses a validated AVD registration and launch receipt.

Eligible booted iOS Simulators are individually shut down and deleted with `simctl`; Android emulators are stopped with their exact ADB serial and removed with `avdmanager`. The worktree path, ownership and device identity are checked again before removal. Failed or unconfirmed shutdown never proceeds to deletion. Other devices, worktrees, branches and source files remain untouched. Deleting a device removes the apps and data stored inside it.

```sh
orchard cleanup --scope orphaned-devices --no-discover --json
orchard cleanup --scope orphaned-devices --no-discover --apply --json
```

`archived-devices` remains a compatibility alias for `orphaned-devices`; it no longer reads archive metadata. `simulators` applies the same missing-worktree rule to iOS only. Explicit `derived-data` and `source-packages` scopes keep their existing cache policies; automatic checks never collect those caches. The default explicit scope is `all`.

Reports include exact device IDs/names, observed state, shutdown requirements and removal/preservation reasons. Inspection never stops or removes a device but may update report/lock metadata. Ownership, `last-report.json`, and pending/completed invocation receipts live under `~/Library/Application Support/Orchard/Cleanup-v1/`. Exclude project paths with `settings.json` containing `{"excludedPaths":["/absolute/path/to/project"]}`. Failed automatic requests are recorded in `invocation-error.json`, cleared after a successful pass. `ORCHARD_DISABLE_BACKGROUND_CLEANUP=1` disables automatic workers in tests.

No cron or LaunchAgent is installed. Go/Gradle/npm caches, DeviceSupport, Simulator runtimes and source worktrees are outside automatic device cleanup.

## Requirements

- macOS 14 or later
- Xcode (with `xcodebuild`, `simctl`, `devicectl` available)

## Installation

Build from source:

```bash
git clone https://github.com/kyoya1123/Orchard.git
cd Orchard
Scripts/package-app.sh
open Orchard.app
```

To use the CLI, symlink the bundled binary onto your `PATH`:

```bash
ln -sf "$PWD/Orchard.app/Contents/MacOS/orchard" /usr/local/bin/orchard
```

> The bundled and bare CLI share automatic project registration and read GUI settings from the `dev.codex.Orchard` preferences domain. The bundle is needed to launch the GUI automatically with `--delegate`.

## Usage

### GUI

1. Use `orchard run`, `orchard list schemes`, or `orchard simulator ensure` from a project. Its repository and worktrees appear in the GUI automatically.
2. Open the Orchard menu bar item. Settings also lets you add directories manually; this is optional.
3. Pick a project, scheme, and destination, then press **Build & Run**.

### CLI

```bash
# Build + install + launch (blocks until the launched app exits)
orchard run --branch <branch> --scheme <scheme> --destination <name-or-udid> \
  [--device | --simulator] [--delegate] [--timeout <seconds>] [--dir <path> ...] [--json]

# Discovery
orchard list branches [--dir <path> ...] [--json]
orchard list schemes --branch <branch> [--dir <path> ...] [--json]
orchard list destinations [--device | --simulator] [--json]

# Observe runs (GUI- and CLI-originated)
orchard runs [--json]        # list every recorded run
orchard runs <id> [--json]   # show one run's detail + log
orchard runs <id> --log      # print only that run's log
```

Branch, scheme, and destination are fuzzy matched (exact → case-insensitive → prefix → substring); a destination UDID matches exactly. Ambiguous input lists the candidates so you can narrow it down.

By default `run` executes attached: it builds and launches in-process, streams the app's console to stdout, and blocks until the app exits. Pass `--delegate` to hand the run to the Orchard app instead — the CLI returns immediately and the GUI owns the run.

Output is designed for agents and scripts:

- Build/tool progress goes to **stderr**; the launched app's console output goes to **stdout**.
- `--json` emits NDJSON events: `{"type":"progress"|"command"|"console"|"result"|"error", ...}`.
- Exit codes: `0` success (or a stop initiated from the GUI), `2` not found, `3` ambiguous, `4` build/launch failed, `130` interrupted.

Runs are shared both ways through an on-disk run store (`~/Library/Application Support/Orchard/runs/`): CLI runs appear in the GUI's Runs list (stoppable and rerunnable from there), and GUI runs are readable via `orchard runs`.

Worktree discovery scope is resolved in this order: `--dir` flags → `ORCHARD_DIRS` environment variable (colon-separated) → the current Xcode project / Git repository → automatically registered repositories plus directories configured in the GUI. The current repository takes precedence so another repository with the same branch name does not make local runs ambiguous.

`run` and `list schemes` register the selected project before listing schemes or building; `simulator ensure` registers the project in its working directory before preparing a Simulator. Registration survives a failed build. There is no setup step or opt-out. Read-only inventory commands (`list branches`, `list destinations`, `runs`) do not add projects. Non-Git projects can also be registered.

The shared registry lives under `~/Library/Application Support/Orchard/Repositories-v1/`. Git common-directory identity deduplicates worktrees and symlinks; nested project locations are remembered relative to the worktree root. Even if the original worktree disappears, discovery follows the remaining worktrees, including external Codex worktrees. Atomic writes and per-repository process locks preserve simultaneous additions. The GUI watches registry changes without periodic polling and scans off the main actor. Repeated use of the same project does not rewrite its registration. Manual directory settings and cleanup ownership records remain independent.

## Development

```bash
swift test              # run tests
Scripts/package-app.sh  # build and package Orchard.app
```

The package has two targets:

- `OrchardCore` — discovery (git worktrees, Xcode projects), `xcodebuild` / `simctl` / `devicectl` orchestration, selection resolving, and the shared run store.
- `OrchardApp` — the `MenuBarExtra` GUI and the CLI entry points.
