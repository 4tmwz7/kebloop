# Kebloop native macOS MVP

## Goal

Build a small, native macOS launcher that feels immediate: press a global shortcut, type an app name or calculation, press Return, and continue working. Match Raycast's core interaction speed with an original, restrained interface.

The repository currently contains only a README and icon. This is a new app, not a migration.

## Proposed defaults

- Swift and AppKit for the launcher panel, input field, results, and keyboard handling. SwiftUI for the settings window.
- A standard Xcode macOS application target; Swift Package Manager only if a dependency is justified.
- macOS 14+ as the initial deployment target, subject to the user's device requirements. Support Apple Silicon and Intel where the build tooling permits.
- A background menu-bar app with no Dock icon, an optional launch-at-login setting, and a configurable global shortcut.
- Default shortcut: Option-Space. Command-Space can be assigned after the user resolves any Spotlight or Raycast conflict.
- Everything runs locally. Settings and usage ranking live in UserDefaults; the app index is a disposable local cache.
- Initial development distribution is a local .app. Signing, notarization, and public distribution are separate release work.

## User experience

One floating panel, approximately 640 points wide, with a large search field, up to seven visible result rows, and a small footer showing the primary action. Place it in the upper center of the display containing the pointer. Keep its position stable while typing.

Use native typography and app icons, subtle material, rounded corners, and a clear selection highlight. Respect light/dark mode, reduced motion, increased contrast, and VoiceOver. Avoid animations that delay input or actions.

- Global shortcut opens the panel with the input immediately focused. Pressing it again closes the panel.
- Each new opening starts with an empty query and recent/frequent apps.
- Typing filters apps immediately; the best result starts selected.
- Up/Down changes selection while input retains keyboard focus.
- Return launches or focuses the selected app, then dismisses the panel. A launch failure leaves a useful error visible.
- A complete math expression produces a calculator result in the same list, selected above app matches.
- Return on a calculation copies the answer and dismisses the panel, restoring the previous app's focus.
- Escape and outside click dismiss the panel. Command-comma opens settings.
- Incomplete math input stays quiet; explicit invalid expressions can show a subtle error without blocking typing.

Raycast reference behavior: apps launch from root search, and calculations appear inline with Return copying the answer. References: https://manual.raycast.com/search-bar and https://manual.raycast.com/calculator

## App launcher

Scan /Applications, /System/Applications, and ~/Applications asynchronously. Discover application bundles inside organizational subfolders, but do not recurse into bundles or expose embedded helper apps. Read bundle display names, bundle identifiers, paths, and icons. Handle unreadable locations and stale entries gracefully.

Cache the index so showing the panel never waits for a scan. Refresh in the background at startup and on application-directory changes, with a fallback rescan. Cache icons separately and load them outside the typing path.

Rank exact names and prefixes first, then word prefixes and fuzzy subsequence matches. Use modest frequency/recency boosts with deterministic tie-breaking. Normalize case and diacritics. Keep selection stable when asynchronous metadata arrives. Duplicate app names show location information; launching uses the selected bundle's URL.

Use NSWorkspace to open apps. If the selected app is already running, activate its existing instance. Do not execute shell commands to launch it.

## Calculator

Use a small tokenizer, expression parser, and evaluator with an explicit grammar. Do not execute input as code. Keep calculation and formatting separate so clipboard output preserves useful precision.

Initial grammar:

- Addition, subtraction, multiplication, division, parentheses, unary signs, and exponentiation.
- Decimal numbers, scientific notation, pi, e, sqrt, abs, and round.
- Explicit percentages: 15% means 0.15; 15% of 200 means 30; 20% off 80 means 64. In ordinary arithmetic, 200 + 10% means 200.1. Document and test this choice.
- Exponentiation is right-associative; conventional precedence gives -2^2 = -4.
- Locale-aware decimal input, including Polish decimal commas. Define separator rules explicitly; avoid ambiguous grouped numbers and multi-argument functions in the first grammar.
- Division by zero, invalid domains, overflow, and excessive expression size produce bounded, non-crashing errors.
- Format ordinary decimal results cleanly, including 0.1 + 0.2. Establish precision and rounding rules before selecting the numeric representation; do not market this as a financial calculator.

Currency rates, unit conversion, date arithmetic, full natural-language math, and automatic paste into other apps are later features. The MVP matches the immediate calculation workflow, not Raycast's entire calculator language.

## Internal structure

Keep a single app target with a few focused components:

- AppController: application lifecycle, menu-bar item, settings, and service wiring.
- LauncherPanelController: panel visibility, display placement, input focus, keyboard actions, and dismissal.
- ApplicationIndex: bundle discovery, cache, icons, refresh, and opening.
- SearchEngine: pure matching and ranking over an in-memory snapshot.
- CalculatorEngine: pure parsing, evaluation, and result formatting.
- LauncherModel: query, typed result list, selection, and action dispatch.
- SettingsStore and HotkeyService: preferences, shortcut registration, conflicts, and login setting.

Register a global shortcut rather than monitoring every keystroke. Avoid an Accessibility permission dependency for core app launching and copy-to-clipboard calculations. Prove shortcut registration and panel behavior in the first milestone before committing to any hotkey library.

Apple API references: https://developer.apple.com/documentation/appkit/nspanel and https://developer.apple.com/documentation/appkit/nsworkspace

## Implementation sequence

1. Native shell and focus prototype. Create the app target, menu-bar item, global shortcut, panel, focused input, and dismissal. Verify across multiple displays, Spaces, and full-screen apps. This is the architectural gate.
2. App launching. Add background indexing, cached icons, matching, keyboard selection, activation, and learned ranking. Deliver a usable launcher before adding calculator complexity.
3. Inline calculator. Implement the agreed grammar, live results, copy behavior, locale rules, and error handling.
4. UI and settings. Refine spacing, material, result rows, accessibility, shortcut recording, and launch at login.
5. Performance and local packaging. Profile release builds, fix responsiveness issues, and produce a runnable .app with build/run instructions.

Once the panel and result model are established, app search and calculator work can be delegated independently. Root coordination owns shared interaction behavior, result ordering, integration, and final review.

## Acceptance criteria

Performance numbers are targets to measure, not claims of Raycast parity. Benchmark a warmed release build on the user's Mac, including a large synthetic application index.

- Warm shortcut-to-focused-input p95 under 100 ms.
- Query-to-updated-results p95 under 20 ms for 1,000 indexed apps; no disk scan or icon decoding on the input path.
- No dropped input when typing immediately after the shortcut; no focus left behind after dismissal.
- Apps can be launched entirely with the keyboard, including from full-screen apps and other Spaces.
- Adding, moving, or deleting an app updates results without restarting Kebloop.
- Calculator regression cases cover precedence, negatives, percentages, decimal commas, precision, malformed input, and resource limits.
- Ranking tests cover exact matches, fuzzy matches, accents, duplicate names, and usage boosts.
- A manual comparison with Raycast uses the same app searches and calculations on the same Mac. Record launcher response separately from the chosen app's own startup time.
- Release build runs without network access and without Accessibility permission for core functionality.

## Deferred scope

Extensions, AI, file search, clipboard history, window management, themes, accounts, syncing, web search, and an action-menu framework. Revisit these after the two core workflows meet the acceptance criteria.
