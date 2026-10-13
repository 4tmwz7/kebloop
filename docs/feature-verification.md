# Milestones 3–4 feature verification

Verified on 2026-10-12 on arm64 macOS 27, using release builds. All tests use isolated preferences, synthetic named pasteboards and temporary files. Personal scripts, shortcuts, clipboard history, and privacy permissions were not modified for testing.

The combined release suite reports **153 tests, zero failures, two opt-in timing tests skipped**. The separate timing profile passes (query median 4.825 ms, p95 12.716 ms; navigation median 0.081 ms). Clipboard tests pass 23 cases; automation tests pass 23 cases; the core suite passes 30 cases with its timing case skipped.

The feature checks below exercise the production stores, parser, subprocess runner, snippet presenter, command registry, and AppKit launcher/action-menu code. Automated AppKit tests do not establish actual VoiceOver speech, physical keyboard layout behavior, or permission-prompt usability.

| Feature | Checks performed | Evidence |
| --- | --- | --- |
| Clipboard count/age retention | Count and age expiration, persisted storage cleanup, current settings applied during initial load | ClipboardHistoryTests |
| Clipboard pins | Pins exempt from count/age, pin limit, freed pin slot, clear includes pins | ClipboardHistoryTests |
| Recording pause | Pause survives relaunch, expired deadline resumes, paused clipboard is not backfilled | ClipboardHistoryTests |
| Privacy/source exclusions | Excluded attributed app, unknown source, sensitive markers suppress text/image/rich formats | ClipboardHistoryTests |
| Clipboard actions | Copy/pin/remove applicability, keyboard navigation through actual action controller, remove pinned/unpinned selected item, preserve query and remaining results | ResultActionTests, MilestoneIntegrationTests |
| Clipboard image/rich formats | Image thumbnail decoding, image/RTF/HTML restoration, text fallback, per-entry/aggregate limits, migration, missing/corrupt attachment recovery, remove/clear/expire file cleanup | ClipboardHistoryTests |
| Snippets | Named create/edit/delete, validation/size bounds, repeated/Unicode/nonrecursive placeholders, missing values, production dialogs with injected responses, preview text, cancel at each step, copy without permission, trusted insertion decision and untrusted copy fallback | SnippetTests |
| Portable snippets/profiles | Legacy configuration decode, export, merge/replace and backup, active profile switching | SnippetTests |
| Unit conversions | Every documented alias, length/mass/temperature/data dimensions, offsets/absolute zero, connectors, decimal commas, locale display, incompatible units, incomplete input | CalculatorTests |
| Date math | Difference/addition syntax, relative dates, locale-ambiguous dates, offsets/Z, current time zone, DST, incomplete input | CalculatorTests |
| Localization | Matching English/Polish catalog keys, valid resources, coverage for all literal/dynamic lookup keys, direct packaged Polish lookup, English and Polish command aliases | LocalizationTests plus catalog audit |
| Command shortcuts | Snippet/script/extension IDs persist, registration released on disable/remove, re-enable registration, Unicode event label with stable hardware key code, recorder cancellation | UserCommandShortcutTests |
| Launcher integration | Enabled/disabled snippet/script/extension results, dynamic command invocation routing, category toggle, Polish aliases | MilestoneIntegrationTests |
| Scripts | Literal base and invocation arguments, success/output, missing runtime/nonzero exit, separate streams/combined bound, timeout/cancel, ordinary descendant cleanup, disable/delete/edit/reload while running, no stale completion, minimal environment | AutomationTests |
| Extension API | Real sample search/result/detail/action/preference round trip, supported version, malformed/incompatible/duplicate/oversized responses, input limits, slow execution keeps main actor responsive, superseded responses discarded, disable/delete/update/reload cancellation and stale state cleanup | AutomationTests |
| Automation import/privacy | Import never executes code, all profiles disabled for review, merge/replace backup, malformed imports atomic, local preference values excluded from exports | AutomationConfigurationTests |
| Responsiveness | Release AppKit typing/navigation profile and standalone file visibility benchmark | performance/feature-verification-results.json |
| Packaging | Release app build, localization bundle included, signature/Info.plist validation | scripts/build-app.sh |

## Fixes found during verification

- Added Remove Item to Clipboard History’s ⌘K menu, including a trash icon and Polish translation. Deleting a pinned or unpinned selection retains the search query.
- Extension updates and reload/profile changes retained stale result/detail/message state. Installation, reload, disable, and removal now clear that state; delayed responses cannot restore it.
- Rich clipboard payloads were dropped when AppKit synthesized plain text above the text limit. Capture now omits oversized plain text while retaining bounded images/RTF/HTML; plain-only oversized entries remain rejected.
- Closing or aborting a snippet preview could be interpreted as Copy. The presenter now copies only for an explicit Copy or Insert response; cancellation/abort leaves the pasteboard unchanged.

## Native UI coverage still pending

Restarting the rebuilt app restored native launcher inspection and confirmed the new commands are present. Opening Settings then closed the native automation pipe again; selecting Kebloop by bundle identifier or app path subsequently timed out. A process sample shows the app’s main thread idle in the normal AppKit event loop, rather than blocked by script/extension work. Resetting the automation session did not restore access to the Settings window. This prevents live verification of settings forms, mouse activation, actual insertion into another app, Accessibility permission prompts, VoiceOver speech, IME composition, physical Polish/non-US shortcut recording, translated layout at large text sizes, and display/Spaces behavior.

The earlier smoke check verified root command visibility, `1 km to m` → `1000 m`, and `ustawienia` → Open Settings. Those checks do not cover the remaining live interactions. Source attribution remains an intentional foreground-app approximation; deliberately detached subprocess descendants remain outside the runner’s lifecycle group.


## Everyday workflow priorities (2026-10-13)

The six suggested priorities are implemented. `swift test -c release` executes 177 tests across Kebloop and KebloopCore: 175 pass, two opt-in timing tests are skipped, and there are zero failures. The release bundle builds and passes the build script's signing verification. `git diff --check` passes.

| Feature | Automated verification |
| --- | --- |
| Clipboard/emoji direct paste and plain text | Permission and secure-input gates; intended foreground app; clipboard revision; cancellation and invalid-target replacement; action applicability; retained clipboard removal workflow |
| Running app controls and focus/hide hotkeys | Service builds; running-dependent action availability; shared hotkey registration/routing regression coverage; restart implementation waits for normal termination |
| System actions | Restart/logout event IDs use macOS confirmation, not immediate logout |
| Basic window management | Visible-frame halves, center, coordinate conversion for displays above/left, next-display clamping, greatest window/display intersection |
| Calculator | Unit and duration conversions, mixed-unit addition/subtraction, known unit/currency ambiguity, named time zones, dated currency result with clean clipboard output, cache limits/expiry, mocked endpoint/response validation, request coalescing, stale offline fallback, persisted accepted history and distinct launcher identities |
| Snippets | Legacy decoding, dynamic values/defaults, literal substitution, keyword uniqueness and boundaries, unresolved-trigger preservation, bounded buffer, deletion count excluding the suppressed delimiter, retained preview/cancel behavior |

Native automation obtained an initial snapshot of the previously running app, then repeatedly returned `timeoutReached` for both AX and screenshot requests; reconnecting with the release bundle after a session reset also timed out. This is not native acceptance of the new release. Direct paste into real apps, typing expansion, app hide/restart behavior, permission dialogs, VoiceOver, physical global hotkeys, multi-display window moves, and supported-macOS coverage remain pending native verification. No force quit, restart/logout/sleep, or actual keystroke insertion was executed against user applications by the tests. Typing expansion remains off by default.

The larger candidates are saved in the [roadmap](roadmap.md#larger-feature-backlog).
