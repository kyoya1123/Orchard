# Orchard

**English** | [日本語](README.ja.md)

Orchard is a macOS menu bar app (and headless CLI) for building and running Xcode apps on simulators and devices — without opening Xcode just to pick a scheme or destination.

It is built with git worktree workflows in mind: point Orchard at the directories where your repositories and worktrees live, and every worktree shows up as a selectable project, labeled by its branch name. Pick a project, a scheme, and a destination, then hit **Build & Run**.

## Features

- **Menu bar UI** — choose project (git branch) / scheme / destination from a compact form, with a one-click **Build & Run** button.
- **Worktree discovery** — scans your configured directories for git repositories and worktrees (`git worktree list`), then finds the nearest `.xcworkspace` / `.xcodeproj` for each. Run multiple branches side by side without switching anything.
- **Simulators and devices** — physical devices and your favorite simulators are listed by default; more simulators are one click away. Favorites are remembered.
- **Run management** — each run has its own console log, **Stop** / **Rerun** / **Close** controls, and status. Runs are grouped per project, and starting a new run on a destination replaces the previous one — just like Xcode's Run button.
- **App console, not build noise** — the log view shows the launched app's console output. Orchard's own build/install diagnostics live in a separate Console screen.
- **Global hotkey** — record a shortcut in Settings and toggle the Orchard window from any app (no accessibility permission required).
- **Shares Xcode's build cache** — builds run through `xcodebuild` with the standard DerivedData location, so Orchard and Xcode reuse each other's build artifacts.
- **Headless CLI for automation** — the same binary doubles as an `orchard` CLI that drives the exact same build/install/launch pipeline, with fuzzy matching, NDJSON output, and a shared run store so the GUI and CLI see each other's runs. Designed to be driven by coding agents.

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

> Running the binary from inside `Orchard.app` matters: a bare binary has no bundle identifier, so it would not share settings (scan directories, favorites) with the GUI.

## Usage

### GUI

1. Open the Orchard menu bar item and go to Settings.
2. Add one or more scan directories (where your repositories / worktrees live).
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

Worktree discovery directories are resolved in this order: `--dir` flags → `ORCHARD_DIRS` environment variable (colon-separated) → directories configured in the GUI.

## Development

```bash
swift test              # run tests
Scripts/package-app.sh  # build and package Orchard.app
```

The package has two targets:

- `OrchardCore` — discovery (git worktrees, Xcode projects), `xcodebuild` / `simctl` / `devicectl` orchestration, selection resolving, and the shared run store.
- `OrchardApp` — the `MenuBarExtra` GUI and the CLI entry points.
