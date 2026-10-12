<p align="center">
  <img src="assets/icon.svg" width="80" height="80" alt="Kebloop icon">
</p>

<h1 align="center">Kebloop</h1>

<p align="center">A native macOS launcher for the things you do every day.</p>

Open apps, find files, run calculations, and reach your clipboard, quicklinks, and emoji from one search field. Built with Swift, AppKit, and SwiftUI, Kebloop lives in the menu bar and opens with **Option-Space**.

## Features

- **App search** with fuzzy matching, aliases, and custom app shortcuts.
- **File search** powered by Spotlight, with Git ignore rules respected.
- **Calculator** with functions, percentages, and copyable results.
- **Clipboard history** for up to 200 text entries, with sensitive clipboard types excluded.
- **Quicklinks** for websites, files, and folders.
- **Emoji picker** with search, categories, and recents.
- **Shut down your Mac** by typing `shutdown` and opening the macOS confirmation.
- **AI handoff** to ChatGPT, Claude, or Siri using your existing apps and accounts.
- **Native appearance** with Liquid Glass on macOS 26+ and popover material on older releases.

Core features run locally without a Kebloop account. AI handoff sends the query to your selected provider; no API key is needed.

## Build and install

**Runtime:** macOS 14 or later. **Build tools:** Xcode 27 or later, including the macOS 27 SDK. The newer SDK is required to compile the interactive glass API; the resulting app still supports macOS 14+.

Select your Xcode toolchain if needed:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

Clone the repository and install:

```sh
git clone https://github.com/kubamus/kebloop.git
cd kebloop
./scripts/install-app.sh
```

The installer builds a release bundle, verifies its signature, installs it at `/Applications/Kebloop.app`, and opens the installed copy. Run the same command after pulling updates. Your preferences and clipboard history are stored outside the app bundle.

If `/Applications` is not writable, install for your user:

```sh
./scripts/install-app.sh --destination "$HOME/Applications"
```

Use `--no-launch` to install without opening the app. To build without installing:

```sh
./scripts/build-app.sh
open dist/Kebloop.app
```

Builds target your Mac's architecture. The script uses an available Apple Development signing identity, falling back to ad-hoc signing. To choose an identity explicitly:

```sh
KEBLOOP_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install-app.sh
```

These are local development builds, not notarized distribution releases. A stable development signature helps macOS retain Siri automation permissions across rebuilds; ad-hoc builds may require granting them again.

## Getting started

| Action | Shortcut |
| --- | --- |
| Open or hide the launcher | Option-Space |
| Select a result | Up / Down |
| Open a result or copy a calculation | Return |
| Close the launcher or return from a command | Escape |
| Open settings | Command-comma |
| Send a query to your AI provider | Tab |

Type **Clipboard History**, **Quicklinks**, **Emoji & Symbols**, or **Open Settings** to open a command. You can change the launcher shortcut in Settings.

Type **shutdown** (or **power off** / **turn off**) and press Return to open the macOS shutdown confirmation. Confirm there to turn off your Mac, or cancel to keep working.

Launch at login is enabled on first launch, subject to macOS approval. Manage it in Settings → General. **Command-Q hides the interface**; use **Quit Kebloop** in the menu-bar menu to exit.

File results depend on Spotlight indexing and macOS access permissions. Siri handoff requires Siri, Type to Siri, and the system permission described in the [usage guide](docs/usage.md#ai-handoff).

## Development

Open `Package.swift` in Xcode, or use the command line:

```sh
swift build
swift test -c release
```

- [Usage guide](docs/usage.md): commands, calculator syntax, privacy, and storage.
- [Performance profiling](docs/performance.md): repeatable latency, CPU, and memory measurements.
- [Project plan](PLAN.md): scope and acceptance targets.
