<img src="assets/icon.svg" width="64" height="64" alt="">

# Kebloop

A native macOS app launcher and inline calculator, built with Swift, AppKit, and SwiftUI. Runs locally without accounts, network services, or external dependencies.

## Build and run

Requires macOS 14+ and Xcode with the Swift toolchain selected.

```sh
./scripts/build-app.sh
open dist/Kebloop.app
```

The script creates an ad-hoc signed release app for the current Mac's architecture. For daily use, copy `dist/Kebloop.app` into `/Applications` and launch that copy before enabling launch at login. This development build is not notarized for public distribution.

Open `Package.swift` in Xcode to edit/debug, or use `swift build`. Tests: `swift test -c release`.

## Using Kebloop

- **Option-Space** opens or closes the launcher.
- Type an app name. **Up/Down** selects a result; **Return** opens it or brings it forward.
- Type math in the same field. Results appear immediately; **Return** copies the answer and closes the launcher.
- **Escape** or an outside click closes the launcher.
- **Command-comma** opens settings. The menu-bar icon also opens the launcher, settings, and a manual app refresh.
- Settings offer Option-Space, Control-Space, Command-Shift-Space, or Command-Space, plus optional launch at login. System shortcuts may need to be reassigned before using the same combination.

## Calculator

Examples: `2*(3+4)`, `2^10`, `sqrt(81)`, `abs(-2)`, `round(2.6)`, `15% of 200`, `20% off 80`.

Supports `+ - * / ^`, parentheses, unary signs, scientific notation, `pi`, `e`, and decimal commas or dots. Powers associate right to left; `-2^2` is `-4`. `%` is a fraction: `200 + 10%` is `200.1`; use `10% of 200` for `20`. Functions take one argument. Thousands grouping, currencies, units, and dates are outside the initial calculator grammar.

Calculations use Double and display up to 16 significant digits with insignificant floating-point noise suppressed. Clipboard output uses the same ungrouped decimal-dot representation. Expression/token/depth limits bound evaluation; unfinished expressions stay quiet.

The panel uses native Liquid Glass on macOS 26+, with interactive glass on macOS 27. Older supported releases use a native popover material. The launcher has no branding or keybinding footer.

## App discovery and storage

Scans `/Applications`, `/System/Applications`, `~/Applications`, and the system Cryptex application directory (Safari), including organizational subfolders. App bundles are not traversed for embedded helpers; hidden and background-only apps are excluded. Cached results appear immediately; scans run in the background on startup, each launcher opening, every five minutes, and manual refresh. Native workspace icons are cached directly and prewarmed in small yielded batches; visible icons take priority.

Search matches exact names, prefixes, word prefixes, and fuzzy subsequences, with a small usage boost. App metadata is cached in `~/Library/Caches/Kebloop/application-index.json`; shortcut preferences and launch counts use UserDefaults. No Accessibility permission is needed for the core workflows.

## Verification

Release XCTest coverage checks matching/ranking, duplicate names, calculator grammar, invalid input, and precision. A synthetic 1,000-app ranking benchmark averaged approximately 9 ms on the development Mac. This measures ranking, not full input-to-render latency or parity with Raycast.

Native UI smoke checks covered live math, clipboard copying, launching TextEdit, global shortcut opening, and settings. Multiple displays, full-screen Spaces, VoiceOver, login startup, and the under-100-ms open target still need broader device testing.

See [PLAN.md](PLAN.md) for scope and acceptance targets.
