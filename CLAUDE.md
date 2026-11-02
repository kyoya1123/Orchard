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
  - `main.swift`: entry point.
  - `OrchardCLI.swift`: root command, shared `--dir`/`--json` options, concrete-type dispatch (`runOrchardCLI`).
  - `RunCommand.swift`: `run` subcommand and exit-code mapping.
  - `RunsCommand.swift` / `StopCommand.swift`: follow and stop runs through the run store.
  - `ListCommand.swift`: `list branches|schemes|destinations`.
  - `SimulatorCommand.swift`: `simulator base|ensure`.
  - `CleanupCommand.swift`: `cleanup` and the hidden `cleanup-worker`.
  - `CLIEnvironment.swift`: directory resolution, fetching, delegation, build-log wiring, signal/timeout handling, NDJSON events, run records.
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

- `SimulatorBaseService` exclusively owns the private `SimulatorBases-v1/devices` device set and its manifest. Default-set branch Simulators are never cleaned up here.
- `simulator base`, `simulator ensure`, and `run --branch-simulator` share the same process lock and service. `Scripts/ios-run.sh` delegates creation to that service.
- A base has system apps only and is initialized by boot/bootstatus/shutdown. Do not install user apps, apply SimSlim, or run it as a build destination.
- Replacement must finish initialization and any requested clone before pruning an older registered base. Recheck identity, Shutdown state and installed apps before deletion. Unknown, busy or modified devices are preserved.
- Latest means installed compatible iOS plus newest iPhone hardware generation, preferring regular Pro within that generation; explicit configuration wins. No Xcode/runtime downloads.

## Background artifact collection

- `ArtifactActivity` records worktree ownership and holds shared process leases through build/install. Release before console attachment; console lifetime must not pin an orphan Simulator.
- `ArtifactCleanup` deletes only attributable DerivedData and named branch Simulators when the owner directory is absent or the latest activity is old enough. Never infer simulator ownership from a branch-shaped name. Standard devices/private bases, exclusions and modified package checkouts remain protected.
- Before deleting a Shutdown Simulator, processes still running from its data directory are orphans (no `launchd_sim`); they are terminated, and the device is preserved if any survive.
- `cleanup-worker` is a hidden CLI entry point spawned independently at background CPU/I/O priority. Its exclusive worker lock prevents overlaps; per-project/device exclusive try-locks skip active operations. DerivedData is moved aside under the lock before slow deletion.
- Test cleanup with injected paths and simulated commands.
