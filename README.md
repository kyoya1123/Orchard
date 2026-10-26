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

Orchard checks for unused artifacts when the app starts, when preparing a branch Simulator, and around package/build operations. Collection runs in a separate background process with low CPU and disk I/O priority. It never waits on the UI thread, and a process lock coalesces overlapping requests.

- An owned branch Simulator is eligible when its recorded worktree disappears, or, while shut down, its latest CoreSimulator/Orchard usage timestamp is **more than one day old**. A booted device counts as currently used; an old boot timestamp alone never qualifies it. Filesystem modification times never establish Simulator use. Unknown timestamps do not satisfy the age rule. Discovery does not reset the retention clock.
- A branch Simulator can also be reclaimed when every live owner is a clean non-default branch whose HEAD is an ancestor of the locally cached `origin/HEAD` target. The normalized branch name must still match the Simulator, protecting worktrees reused for a different branch. This is local ancestry evidence, not a fresh GitHub PR check: no fetch/prune, network requests or Git writes occur; squash merges may remain unrecognized.
- DerivedData retains the existing **seven-day** or missing-worktree policy.
- A booted Simulator may be shut down and deleted only for the missing-worktree or verified-merge conditions, after checking that no app, console, debugger, build or owner worktree is actively using it. Only recognized system processes are ignored for its open-file check. Unknown processes, transitioning states, standard-name devices, private bases, renamed devices and devices without an established owner are preserved.
- Orchard builds, Simulator preparation and installation hold process-shared leases. A collector skips busy artifacts. External builds and open files/working directories under the owning worktree or Simulator also preserve the device. A dormant shell or attached console may conservatively defer collection. State and usage are rechecked before each deletion. DerivedData collection also defers during external `xcodebuild` activity, when an Xcode build service has that directory open, or when a package checkout contains local changes.
- Worktree directories, branches and source files are never deleted. Ownership comes from recorded project paths and configured repositories, including registered external/Codex worktrees. A missing external worktree needs a previously recorded association; names alone are not ownership proof.

Inspect with `orchard cleanup --json`; this does not stop Simulators or delete artifacts. Reports include exact device IDs, names, observed state, `requiresShutdown`, usage timestamps, candidate sizes and removal/preservation reasons. Shutdown is per-device, followed by another state/use/ownership check; an unconfirmed shutdown is not retried and never proceeds to deletion. New use after shutdown leaves the device stopped but preserved, reported as `stopped-preserved`. Size estimates can double-count APFS shared blocks; measure actual free space separately. Inspection may update ownership/report metadata and lock files. Use `orchard cleanup --apply` for an explicit collection; Simulator deletion permanently removes installed apps and in-device data.

Limit inspection and application with `--scope simulators`, `--scope derived-data`, or `--scope source-packages` (default: `all`). `--no-discover` uses existing ownership records. For example:

```sh
orchard cleanup --scope simulators --no-discover
orchard cleanup --scope simulators --no-discover --apply
```

Managed SourcePackages entries need a matching owner receipt and a known project record. Only a missing worktree with clean, pinned dependencies and no busy build/cache lease is eligible. Extra files/checkouts, local commits, ignored/untracked files, local/edited dependencies, unknown ownership or inspection errors preserve the entry. Existing caches acquire a receipt the next time this version of Orchard uses them. Templates and live-worktree caches are retained.

Go, Gradle, npm, DeviceSupport and Simulator runtimes are outside this collector's scope. Ownership and the last report live in `~/Library/Application Support/Orchard/Cleanup-v1/`. To exclude a project, put `{"excludedPaths":["/absolute/path/to/project"]}` in that directory's `settings.json`. This is a retention policy, not a disk-size quota; the next use rebuilds deleted products. No cron or LaunchAgent installation is needed. Collection runs when Orchard is used, not while it remains unused.

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
