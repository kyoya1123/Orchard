# Orchard — Internal Notes

User-facing documentation lives in `README.md` (English) and `README.ja.md` (Japanese). This file holds internal behavior details and guidance for coding agents.

Orchard is a command-line tool. It is intentionally repository-agnostic: usage automatically registers repositories, and Orchard discovers Xcode projects and git worktrees inside them. Do not add assumptions tied to any specific repository.

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
  - A locked device is not a failure: `DeviceLockDetector` classifies the command's output tail, and install/launch retry every 3 seconds (indefinitely) while reporting `Waiting for device unlock`. `orchard stop`, Ctrl-C, and `--timeout` are the ways out.
- Stop:
  - Always terminates the launched app, not only the local build process.
  - Simulator stop uses `simctl terminate`.
  - Device stop resolves the installed app URL and running process IDs through `devicectl device info apps/processes`, then terminates matching processes.

`--console` keeps the launch process attached after the app starts. This is why a run stays `running` after the build is already done.

## Run Lifecycle

See `README.md` for the user-facing reference. Internal details:

- By default `run` runs attached: it resolves the worktree/scheme/destination, builds and launches in-process, streams the app's console to stdout, and blocks until the app exits.
- `--delegate` resolves (and prepares a `--branch-simulator` destination) in the calling process, then re-executes the same arguments plus hidden `--run-id <id> --quiet` as a new session (`posix_spawn` + `POSIX_SPAWN_SETSID`, stdio on `/dev/null`) and returns once that run's record exists. The run therefore survives the calling shell or agent task. Exit code reflects delegation (`0` delegated, `2` not found, `3` ambiguous, `4` the child did not start).
- Every run writes a `RunRecord` to `~/Library/Application Support/Orchard/runs/<id>.json` with the owning PID. `orchard runs` reads them; `orchard stop <id>` sends `SIGTERM` to the owner and waits for it to exit.
- `SIGTERM` (from `stop` or a superseding run) tears down the launched app and exits `0` as `stopped`, so a background task does not see a crash. `SIGINT` does the same teardown and exits `130`.
- One run per destination: starting a run on a destination stops and removes any existing run there.
- `runs` marks `running` records whose owner process is gone as `stopped`, prunes finished records after 24h, and drops records whose project file no longer exists.
- Record state:
  - Build progress is represented by non-empty `activityText`.
  - `running` with an empty `activityText` means the app launched and the console is attached. Callers poll for exactly this, so keep it stable.
- Directory precedence: `--dir` → `ORCHARD_DIRS` → current project/repository → auto-registered repositories plus `configuredDirectoryPaths` from the `dev.codex.Orchard` defaults domain.
- `RepositoryRegistry` uses canonical Git common-directory identity, relative project locations, atomic per-repository records and process locks. Registration happens before scheme/build/Simulator work and has no opt-out. `list branches`/destinations/runs remain read-only. Discovery metadata must not replace artifact ownership history. Identical registration does not rewrite files.

## Discovery Model

1. Usage registers a project; `configuredDirectoryPaths` may add scan directories.
2. `WorktreeContextResolver` merges configured-directory discovery with registered repositories.
3. It finds git repositories.
4. For each repository, it runs `git worktree list --porcelain`.
5. It creates one `WorktreeContext` per worktree.
6. It discovers `.xcworkspace` or `.xcodeproj`, including relative nested project locations recorded by usage.

Fallback scanning also checks `.worktrees` and `.claude/worktrees`.

## Source Map

- `Sources/OrchardCLI/`
  - `OrchardCLI.swift`: `@main` root command, shared `--dir`/`--json` options and directory resolution, JSON output.
  - `RunCommand.swift`: `run` subcommand and exit-code mapping.
  - `RunsCommand.swift` / `StopCommand.swift`: follow and stop runs through the run store.
  - `ListCommand.swift`: `list branches|schemes|destinations`.
  - `SimulatorCommand.swift`: `simulator base|ensure`.
  - `DeviceUseCommand.swift`: `device-use`, wrapping an external command in a device activity lease.
  - `CleanupCommand.swift`: `cleanup` and the hidden `cleanup-worker` (`--devices-only` drains `CleanupInvocation`).
  - `CLIEnvironment.swift`: fetching, delegation, build-log wiring, signal/timeout handling, NDJSON events, run records.
- `Sources/OrchardCore/WorktreeContext.swift`
  - Worktree and configured-directory discovery.
- `Sources/OrchardCore/ProjectDetector.swift`
  - Finds `.xcworkspace` or `.xcodeproj`.
- `Sources/OrchardCore/GitService.swift`
  - Git root/branch/worktree calls.
- `Sources/OrchardCore/XcodeService.swift`
  - Schemes, destinations, build settings.
- `Sources/OrchardCore/SourcePackageCache.swift`
  - APFS-cloned SPM templates, per-project process locks, path rebasing, and bounded immutable snapshots. `schemes`, build and buildSettings must keep the same package arguments. The lease ends before app launch/console attachment.
- `Sources/OrchardCore/BuildRunService.swift`
  - Build/install/launch/stop implementation.
- `Sources/OrchardCore/DeviceLockDetector.swift`
  - Classifies a failed `devicectl` command's output as "device is locked".
- `Sources/OrchardCore/XcodeModels.swift`
  - Shared model types.
- `Sources/OrchardCore/SelectionResolver.swift`
  - Resolves human-readable branch/scheme/destination names to model objects (staged fuzzy matching).
- `Sources/OrchardCore/AppConfiguration.swift`
  - Defaults domain and keys.
- `Sources/OrchardCore/RunRecord.swift` / `RunStore.swift`
  - Serializable run snapshot and the on-disk store (`Application Support/Orchard/runs/`).
- `Scripts/install.sh`
  - Builds a release binary and installs it as `~/.local/bin/orchard` (override with `ORCHARD_INSTALL_DIR`).

## Development Commands

```bash
swift test
Scripts/install.sh
```

Install by rename so running delegated runs keep their old binary.

## Notes For Future Agents

- Keep Orchard generic. Do not add repository-specific assumptions.
- If changing build performance behavior, remember that omitting `-derivedDataPath` is intentional to share standard Xcode DerivedData.
- After changes, run `swift test`, then `Scripts/install.sh`.

## Simulator base ownership

- `SimulatorBaseService` exclusively owns the private `SimulatorBases-v1/devices` device set and its manifest, including the `clones` registry of default-set branch Simulators it cloned or adopted from exact UDID/name ownership records.
- `simulator base`, `simulator ensure`, and `run --branch-simulator` share the same process lock and service. `Scripts/ios-run.sh` delegates creation to that service. `run --destination` re-resolves an owned destination through `prepareManagedDestination`.
- A base has system apps only and is initialized by boot/bootstatus/shutdown. Do not install user apps, apply SimSlim, or run it as a build destination.
- Bases coexist per device type and runtime. Replacement must finish initialization and any requested clone before pruning an older registered base of the same target. Recheck identity and installed apps; a booted obsolete base is shut down first. Unknown or modified devices are preserved.
- A clone is obsolete only when its recorded runtime build differs for the same device type and runtime. Xcode build or simctl path changes keep it. A booted obsolete clone is reused until it is shut down; only shut-down ones are deleted, after the device lease is free. Legacy clones without a recorded configuration are never obsolete.
- Latest means installed compatible iOS plus newest iPhone hardware generation, preferring regular Pro within that generation; explicit configuration wins. Runtime support comes from simctl's per-runtime list first, then the device's min/max range; missing metadata is unsupported. No Xcode/runtime downloads.

## Background artifact collection

- `ArtifactActivity` records worktree ownership and holds shared process leases through build/install. Release before console attachment; console lifetime must not pin an orphan Simulator.
- `ArtifactCleanup` deletes only attributable DerivedData and named branch Simulators when the owner directory is absent or the latest activity is old enough. Never infer simulator ownership from a branch-shaped name. Standard devices/private bases, exclusions and modified package checkouts remain protected.
- Age and merge reasons apply to Shutdown Simulators only. A Booted Simulator is shut down by its UDID and collected only when every owner worktree is missing; external use is judged after that shutdown (a booted device's own system processes always hold its data open).
- When every existing owner worktree is a worktree root with another branch checked out (`branchSwitched`), a Booted Simulator is only shut down, and open files under those reused folders are excluded from the usage check of the shut-down rules. Detached HEADs and Git errors are never a switch.
- Before deleting a Shutdown Simulator, processes still running from its data directory are orphans (no `launchd_sim`); they are terminated, and the device is preserved if any survive.
- `DeviceWindowCloser` closes a removed device's standalone compact Device Hub window through Accessibility. Window closing is best effort: a failure (no permission, tabs, ambiguity) is reported as `window-left-open` and never blocks shutdown or deletion, because otherwise nothing could be collected without the permission.
- `DeviceActivity` receipts (`device-use/`) count as Simulator use; an unreadable receipt counts as current use.
- `AVDCleanup` deletes only AVDs whose directory contains an `orchard-owner.json` marker written by the tool that created them, when the marked worktree is missing (stop and delete), or when the marker's `branch` is no longer checked out there (stop; delete once the marker's `lastUsedAt` is over a day old). Orchard never creates, launches or adopts AVDs, and never infers AVD ownership from names, launch parameters or launch directories. Markers without `branch`/`lastUsedAt` only get the missing-worktree rule.
- `cleanup-worker` is a hidden CLI entry point spawned independently at background CPU priority. Do not set a process-wide I/O throttle: it is inherited by utility-QoS simctl/ADB/avdmanager children and makes their bounded IPC time out. Its exclusive worker lock prevents overlaps; per-project/device exclusive try-locks skip active operations. DerivedData is moved aside under the lock before slow deletion.
- `run`, `list`, `runs` and `simulator` call `BackgroundCleanup.request()` from `OrchardCLI.main()`: a durable `CleanupInvocation` request plus a `cleanup-worker --devices-only` pass over recorded Simulators and marked AVDs without repository discovery. Help and `cleanup` never schedule an apply pass. Activity begin/finish still schedules the full collection.
- Test cleanup with injected paths and simulated commands.
