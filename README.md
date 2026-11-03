# Orchard

**English** | [日本語](README.ja.md)

Orchard is a macOS command-line tool for building and running Xcode apps on simulators and devices — without opening Xcode just to pick a scheme or destination. It is designed to be driven by coding agents.

It is built with git worktree workflows in mind: use a project once and its repository is registered automatically, so every worktree can be selected by its branch name.

## Features

- **Worktree discovery** — discovers registered repositories and optionally configured directories through `git worktree list`, then finds the nearest `.xcworkspace` / `.xcodeproj` for each. Run multiple branches side by side without switching anything.
- **Simulators and devices** — fuzzy-matched destinations, plus per-branch Simulators cloned from an empty base.
- **Run management** — `run --delegate` returns immediately while a background process keeps the app's console attached; `runs` follows any run and `stop` ends it. Starting a new run on a destination replaces the previous one — just like Xcode's Run button.
- **Shares Xcode's build cache** — builds run through `xcodebuild` with the standard DerivedData location, so Orchard and Xcode reuse each other's build artifacts.
- **Agent-friendly output** — fuzzy matching, stable exit codes, and NDJSON output.

## Swift package disk usage

Orchard reuses the project's existing `DerivedData/SourcePackages` when present. For new worktrees it keeps a private package directory under `~/Library/Caches/Orchard/SourcePackages-v1/`, seeded from an APFS copy-on-write template. Templates are keyed by Git repository, `Package.resolved` and the selected Xcode; at most three templates per repository are retained. Source changes remain private to each worktree.

Scheme listing, builds and build-product lookup use the same package directory. Commands for the same project are serialized across processes until build-product lookup finishes; different worktrees can still build concurrently. The normal DerivedData build location remains unchanged. A successful resolution/build publishes a template only when the pinned Git checkouts are clean and artifact paths are self-contained. Local/registry packages and unsupported lockfile formats use normal Xcode behavior. Failed clones fall back to Xcode resolution, never a full copy.

This reduces growth from new worktrees; it does not shrink existing Build products or Simulator data. The SPM sharing service does not delete per-worktree checkouts while building. Managed caches record their owner and pinned dependency revisions. The separate collector below can reclaim a cache only after its recorded worktree disappears and its pinned checkouts remain unchanged. Legacy entries without a receipt, live-worktree caches, templates and manual dependency edits remain protected. To opt out, run Orchard with `ORCHARD_SPM_CACHE=0`. After stopping builds, immutable `templates/` subdirectories can be removed to reclaim unused snapshots; private `worktrees/` directories may contain edits and require manual review before removal.

## Empty Simulator bases

`orchard run --branch <branch> --scheme <scheme> --branch-simulator` prepares a branch Simulator automatically. Orchard checks the selected Xcode's installed, available iOS runtimes on each request, chooses the newest compatible iPhone hardware generation (preferring Pro within a generation), and reuses an exact matching branch Simulator or clones a base with `simctl clone`. It does not download runtimes. Explicit `--device-type` and `--runtime` values override automatic selection. Existing `--destination` runs are unchanged.

A base is created, booted through `simctl bootstatus`, checked for system apps only, then shut down. Orchard installs no app and applies no app settings to it. Bases are stored in a separate CoreSimulator device set under `~/Library/Application Support/Orchard/SimulatorBases-v1/devices`, so they do not appear among normal run destinations. The registry includes the device type, runtime build, Xcode build/tool path and initialization revision. Matching bases are reused; changes prepare a new base on demand, not a new base for every build.

Bases coexist per device type and runtime. After preparation (and cloning, when requested) succeeds, only obsolete registered bases of the same device type and runtime are deleted, and only if unmodified in identity and free of user-installed apps; a booted obsolete base is shut down first. Busy/modified bases are preserved with a diagnostic and retried later. Failed initialization/cloning retains the previous base. Unmanaged devices—including a legacy device named `base`—are never deleted by this feature. Cross-process locking prevents duplicate initialization. APFS sharing reduces growth of new Simulators; it does not compact existing ones or prevent new logs/app data from accumulating.

Branch Simulators cloned by Orchard survive Xcode or simctl updates. Only a changed build of the same runtime replaces one: a shut-down clone is deleted and cloned again under the same name, while a booted clone keeps being used and is replaced by the next preparation after it stops. Selecting another device type or runtime never deletes other Simulators. A managed Simulator passed as `--destination` is resolved through the same path, so a run never launches a replaced clone's stale UDID.

With `--runtime` omitted, Orchard picks the newest installed iOS runtime that supports the requested device type. simctl's per-runtime supported-device list wins over the device's min/max runtime range. Unsupported combinations fail before anything is created or deleted, listing the compatible installed runtimes.

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

Orchard checks for unused artifacts when preparing a branch Simulator and around package/build operations. In addition, every `run`, `list`, `runs` and `simulator` invocation checks devices (Simulators and marked AVDs) using existing ownership records only. Collection runs in a separate background process with low CPU priority; only its `simctl`, `adb` and `avdmanager` clients run at utility QoS so their IPC cannot stall. Overlapping requests are coalesced, and a request arriving during a pass triggers another pass. A failed request is recorded in `invocation-error.json` and kept pending until the next invocation.

- An owned branch Simulator is eligible when its recorded worktree disappears, or its latest CoreSimulator/Orchard usage timestamp is **more than one day old**. Filesystem modification times never establish Simulator use. Unknown timestamps do not satisfy the age rule. Discovery does not reset the retention clock.
- A stopped branch Simulator can also be reclaimed when every live owner is a clean non-default branch whose HEAD is an ancestor of the locally cached `origin/HEAD` target. The normalized branch name must still match the Simulator, protecting worktrees reused for a different branch. This is local ancestry evidence, not a fresh GitHub PR check: no fetch/prune, network requests or Git writes occur; squash merges may remain unrecognized.
- DerivedData retains the existing **seven-day** or missing-worktree policy.
- A booted Simulator is shut down and collected only when every owning worktree has disappeared. When every existing owner worktree has another branch checked out (a reused folder), the device is only shut down, and the shut-down rules collect it later; files open in that folder then no longer count as use of the device. Detached HEADs and Git errors never count as a switch. Otherwise a booted device is preserved regardless of age or merge state. External use is checked again after the targeted shutdown; a device still in use stays stopped but preserved. Processes left running from a shut-down Simulator's data directory are terminated before it is deleted; if any survive, the Simulator is preserved. Standard-name devices, private bases, renamed devices and devices without an established owner are preserved.
- Before a Simulator is deleted, its Device Hub window is closed through the macOS Accessibility close button, but only a standalone compact window whose name and runtime match uniquely. `simctl shutdown`/`delete` alone leave the window open. Without Accessibility permission for the app that runs `orchard`, or for tabbed, full or unidentifiable windows, the window is left open, collection continues and the report records `window-left-open`. Device Hub itself is never quit.
- Orchard builds, Simulator preparation and installation hold process-shared leases. A collector skips busy artifacts. External builds and open files/working directories under the owning worktree or shut-down Simulator also preserve the device. Wrap external tests as `orchard device-use --simulator <UDID> -- xcodebuild ... test` to protect the device until the command exits and to count it as use. A dormant shell or attached console may conservatively defer collection. State and usage are rechecked before each deletion. DerivedData collection also defers during external `xcodebuild` activity, when an Xcode build service has that directory open, or when a package checkout contains local changes.
- Worktree directories, branches and source files are never deleted. Ownership comes from recorded project paths and configured repositories, including registered external/Codex worktrees. A missing external worktree needs a previously recorded association; names alone are not ownership proof.

### Accessibility permission for closing Device Hub windows

Windows are closed with the permission of the app that launched `orchard`: `Claude` for the Claude Code desktop app, `Terminal`, `Ghostty`, `iTerm` or similar when run from a terminal, `Codex` for Codex. Grant Accessibility to that app, not to the `orchard` binary.

1. Open System Settings › Privacy & Security › Accessibility:

   ```bash
   open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
   ```

2. Turn the app's switch on. If it is not listed, add it with "+" from `/Applications` (Terminal lives in `/System/Applications/Utilities`).
3. If the change does not take effect, quit and reopen that app.

Check the result with `orchard cleanup --json` while Device Hub is running: the `"target" : "Device Hub windows"` entry reports `"outcome" : "available"` when granted and `"permission-required"` otherwise. Revoke it by turning the switch off, or reset it by bundle ID, for example `tccutil reset Accessibility com.anthropic.claudefordesktop`. Accessibility lets the app control other apps, so grant it only where needed.

Inspect with `orchard cleanup --json`; this does not stop devices or delete artifacts. Reports include exact device IDs, names, observed state, whether a shutdown is required (`requiresShutdown`), usage timestamps, candidate sizes and removal/preservation reasons. Size estimates can double-count APFS shared blocks; measure actual free space separately. Inspection may update ownership/report metadata and lock files. Use `orchard cleanup --apply` for an explicit collection; Simulator deletion permanently removes installed apps and in-device data.

Limit inspection and application with `--scope devices` (Simulators and marked AVDs), `--scope simulators`, `--scope emulators`, `--scope derived-data`, or `--scope source-packages` (default: `all`). `--no-discover` uses existing ownership records. For example:

```sh
orchard cleanup --scope simulators --no-discover
orchard cleanup --scope simulators --no-discover --apply
```

Managed SourcePackages entries need a matching owner receipt and a known project record. Only a missing worktree with clean, pinned dependencies and no busy build/cache lease is eligible. Extra files/checkouts, local commits, ignored/untracked files, local/edited dependencies, unknown ownership or inspection errors preserve the entry. Existing caches acquire a receipt the next time this version of Orchard uses them. Templates and live-worktree caches are retained.

Go, Gradle, npm, DeviceSupport and Simulator runtimes are outside this collector's scope. Ownership and the last report live in `~/Library/Application Support/Orchard/Cleanup-v1/`. To exclude a project, put `{"excludedPaths":["/absolute/path/to/project"]}` in that directory's `settings.json`. This is a retention policy, not a disk-size quota; the next use rebuilds deleted products. No cron or LaunchAgent installation is needed. Collection runs when Orchard is used, not while it remains unused. Set `ORCHARD_DISABLE_BACKGROUND_CLEANUP=1` to disable automatic collection in isolated tests.

## Android AVD cleanup

Orchard does not create or run Android emulators; it only deletes AVDs whose owner said so. A tool that creates an AVD for a worktree opts in by writing `orchard-owner.json` inside the AVD directory (`<ANDROID_AVD_HOME>/<name>.avd/`) with the worktree's absolute path:

```json
{"worktreePath": "/absolute/path/to/worktree", "branch": "feature/example", "lastUsedAt": 1793000000}
```

`branch` and `lastUsedAt` (Unix seconds) are optional; rewriting the marker on each use records the last use.

When that worktree no longer exists, a running emulator for the AVD is stopped with `emu kill` on its own ADB serial, its disconnect is confirmed, and the AVD is deleted with `avdmanager delete avd`. When the worktree has a branch other than `branch` checked out, a running emulator is stopped, and the AVD is deleted once `lastUsedAt` is more than a day old. Markers without `branch`, and detached HEADs, never trigger this rule. AVDs without the marker are never touched; ownership is never inferred from names or launch directories. A symlinked or unreadable marker, a relative path or an inaccessible worktree preserves the AVD, and age alone never removes one. The Android SDK is located through `ANDROID_HOME`, `ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`; AVDs through `ANDROID_AVD_HOME`, then `~/.android/avd`.

## Requirements

- macOS 14 or later
- Xcode (with `xcodebuild`, `simctl`, `devicectl` available)

## Installation

Build from source and install `orchard` into `~/.local/bin` (set `ORCHARD_INSTALL_DIR` to choose another directory on your `PATH`):

```bash
git clone https://github.com/kyoya1123/Orchard.git
cd Orchard
Scripts/install.sh
```

## Usage

```bash
# Build + install + launch (blocks until the launched app exits)
orchard run --branch <branch> --scheme <scheme> --destination <name-or-udid> \
  [--device | --simulator] [--delegate] [--timeout <seconds>] [--dir <path> ...] [--json]

# Discovery
orchard list branches [--dir <path> ...] [--json]
orchard list schemes --branch <branch> [--dir <path> ...] [--json]
orchard list destinations [--device | --simulator] [--json]

# Follow and stop runs
orchard runs [--json]        # list every recorded run
orchard runs <id> [--json]   # show one run's detail + log
orchard runs <id> --log      # print only that run's log
orchard stop <id>            # stop the run and terminate the launched app

# Devices
orchard simulator ensure --name <name> [--device-type <type>] [--runtime <runtime>]
orchard device-use --simulator <udid> [--timeout <seconds>] -- <command> ...
orchard cleanup [--apply] [--scope <scope>] [--no-discover]
```

Branch, scheme, and destination are fuzzy matched (exact → case-insensitive → prefix → substring); a destination UDID matches exactly. Ambiguous input lists the candidates so you can narrow it down.

By default `run` executes attached: it builds and launches in-process, streams the app's console to stdout, and blocks until the app exits. Pass `--delegate` to run it in a detached background process instead: the command returns as soon as the run has started and prints its id (`Delegated to Orchard: … · run <id>`). The run keeps going after the calling shell exits; follow it with `orchard runs <id>` and end it with `orchard stop <id>`. A run whose status is `running` with an empty `activityText` has launched the app and is attached to its console.

Output is designed for agents and scripts:

- Build/tool progress goes to **stderr**; the launched app's console output goes to **stdout**.
- `--json` emits NDJSON events: `{"type":"progress"|"command"|"console"|"result"|"error", ...}`.
- Exit codes: `0` success (or stopped with `orchard stop` / by a newer run), `2` not found, `3` ambiguous, `4` build/launch failed, `130` interrupted.

Every run is recorded under `~/Library/Application Support/Orchard/runs/`. Records whose process has exited are shown as `stopped`; finished records are pruned after 24 hours.

Worktree discovery scope is resolved in this order: `--dir` flags → `ORCHARD_DIRS` environment variable (colon-separated) → the current Xcode project / Git repository → automatically registered repositories plus directories in `defaults read dev.codex.Orchard configuredDirectoryPaths`. The current repository takes precedence so another repository with the same branch name does not make local runs ambiguous.

`run` and `list schemes` register the selected project before listing schemes or building; `simulator ensure` registers the project in its working directory before preparing a Simulator. Registration survives a failed build. There is no setup step or opt-out. Read-only inventory commands (`list branches`, `list destinations`, `runs`) do not add projects. Non-Git projects can also be registered.

The shared registry lives under `~/Library/Application Support/Orchard/Repositories-v1/`. Git common-directory identity deduplicates worktrees and symlinks; nested project locations are remembered relative to the worktree root. Even if the original worktree disappears, discovery follows the remaining worktrees, including external Codex worktrees. Atomic writes and per-repository process locks preserve simultaneous additions. Repeated use of the same project does not rewrite its registration. Configured directories and cleanup ownership records remain independent.

## Development

```bash
swift test           # run tests
Scripts/install.sh   # build and install the release binary
```

The package has two targets:

- `OrchardCore` — discovery (git worktrees, Xcode projects), `xcodebuild` / `simctl` / `devicectl` orchestration, selection resolving, and the run store.
- `OrchardCLI` — the `orchard` command.
