# Kebloop feature roadmap

Status: milestones 1–2 implemented; native acceptance verification pending as noted below. Updated: 2026-10-12.

This roadmap turns the feature proposals into implementation chunks. Each chunk should be delivered and verified independently. Check a chunk only when its acceptance criteria are met, and record any follow-up work here.

The original [MVP plan](../PLAN.md) remains a historical design reference. This document describes the next stages of the existing Swift, AppKit, and SwiftUI app.

## Goals and implementation rules

- Let users customize search, appearance, shortcuts, and workflows.
- Make core workflows discoverable and accessible across supported macOS versions.
- Add automation progressively, beginning with quicklinks and Apple Shortcuts before scripts and a larger extension API.
- Preserve fast local search, keyboard operation, and account-free core features.
- Follow the current native architecture. Introduce shared infrastructure when a chunk needs it, rather than refactoring everything in advance.
- Retain existing preferences through migrations. New features must not silently replace user choices.
- Use stable identifiers for commands and actions from the start, and extract new user-facing strings for localization as features are added. Chunk 14 delivers translations and the broader language/layout audit.
- Treat clipboard history, credentials, caches, and usage history separately from portable configuration.

## Delivery order

| Milestone | Chunks | Outcome |
| --- | --- | --- |
| 1: Personalization and access | 01–06 | Accessibility, actions, search controls, appearance, command shortcuts, and portable settings |
| 2: Discoverable workflows | 07–10 | Help, parameterized links/web search, Apple Shortcuts, and profiles |
| 3: Everyday utilities | 11–15 | Clipboard controls, snippets, conversions/date math, localization, and richer clipboard formats |
| 4: User automation | 16–17 | Script commands, then a small extension API informed by real use |
| Release engineering | 18–19 | Signed/notarized downloads and updates; can run alongside feature milestones |

The order is a recommendation, not a requirement to finish every earlier milestone before starting an independent chunk. Dependencies below take precedence. Chunk 18 can begin early once signing credentials and a distribution destination are available.

## Implementation chunks

### 01 — Accessibility baseline

- [ ] Complete
- **Scope:** Audit launcher, settings, clipboard, quicklinks, emoji, and shortcut recording with VoiceOver and keyboard-only navigation. Fix labels, selection announcements, focus restoration, and unreachable controls. Respect system reduced motion, increased contrast, and reduced transparency.
- **Acceptance:** A user can search, select, execute, go back, and change settings with VoiceOver or the keyboard. System accessibility settings produce legible UI. Verify on supported macOS versions, multiple displays, and full-screen Spaces where devices are available; document coverage gaps.
- **Dependencies:** None. Repeat relevant checks as new UI ships.
- **Delivery (2026-10-12):** Accessibility labels, keyboard focus/activation, selection announcements, input-method guards, custom action panels, and contrast/transparency handling are implemented in [launcher](../Sources/Kebloop/LauncherPanelController.swift), [settings](../Sources/Kebloop/SettingsView.swift), and [emoji picker](../Sources/Kebloop/EmojiPicker.swift). Native UI automation timed out on this host; VoiceOver speech, keyboard traversal, macOS 14–26, multiple displays, and full-screen Spaces still require manual verification.


### 02 — Result action menu

- [ ] Complete
- **Scope:** Add a keyboard- and mouse-accessible action menu, initially opened with `⌘K`. Support file actions (reveal in Finder, copy path, open with), quicklink editing, and pin/unpin for supported result types. Preserve Return as the primary action. Give persisted pins stable identities.
- **Acceptance:** Only applicable actions appear. Escape returns to the selected result. Actions work with VoiceOver and report failures without losing the query. Pins survive relaunch and appear predictably in root search.
- **Dependencies:** 01 for interaction conventions. Use a small shared action model with stable identifiers that later commands can reuse.
- **Delivery (2026-10-12):** [Stable result actions](../Sources/Kebloop/ResultAction.swift) and launcher ⌘K/mouse action panels implement file reveal/copy/open-with, quicklink editing, and persistent favorites. Action applicability is regression-tested. Native menu Escape/focus and Finder/open-with interaction remain unverified on this host.


### 03 — Search customization

- [ ] Complete
- **Scope:** Add category toggles, searchable-folder selection, user exclusions, hidden apps, and management of pinned favorites. Allow choosing whether the empty launcher shows favorites, frequent apps, or recent apps. Provide reset-to-default controls.
- **Acceptance:** Saved settings affect fresh and cached results consistently. Folder matching respects path boundaries. Unavailable folders and access restrictions show useful feedback. Exact matches and existing aliases retain predictable ranking. Disabled categories do not keep unnecessary background work running.
- **Dependencies:** 02 for favorites. Keep privacy-related exclusions distinct from optional relevance filters.
- **Delivery (2026-10-12):** [Personalization](../Sources/Kebloop/PersonalizationStore.swift) and settings implement categories, folders, exclusions, hidden apps, favorites, recent/frequent/favorite defaults, and reset. [File search](../Sources/Kebloop/FileSearchService.swift) applies filters before bounded ranking, including cached results; disabled files stop indexing and disabled apps skip periodic refresh. Boundary, persistence, and launcher category/favorite tests pass. Folder access feedback needs native UI verification.


### 04 — Appearance and layout controls

- [ ] Complete
- **Scope:** Add system/light/dark appearance, text size, panel width, comfortable/compact row density, transparency preference, and placement on the pointer display, active-window display, or a chosen display.
- **Acceptance:** Changes preview immediately and persist. Larger text does not clip actions or results. System accessibility preferences override incompatible visual effects. Missing displays fall back gracefully; the panel remains within usable screen bounds.
- **Dependencies:** 01. Coordinate layout changes with 02.
- **Delivery (2026-10-12):** Settings implement live appearance, text size, width, density, transparency, and display placement. The launcher respects increased contrast/reduced transparency, uses no animated transitions, and constrains placement to visible screen bounds. Active placement uses the previous foreground app’s visible window when macOS provides bounds. Large-text, display removal, and accessibility-effect previews await native verification.


### 05 — Shortcuts for any command

- [ ] Complete
- **Scope:** Reuse the app shortcut recorder for the launcher, clipboard, emoji, quicklinks, and built-in commands. Introduce stable command identifiers and a small command registry so future user commands can register shortcuts.
- **Acceptance:** Assignments persist and resolve after relaunch. Duplicate, launcher, and unavailable system shortcut conflicts are explained. Recording and cancellation restore registrations. Disabling or deleting a command removes its active binding safely.
- **Dependencies:** 02 action conventions. Preserve existing app shortcut assignments.
- **Delivery (2026-10-12):** [Command registry](../Sources/Kebloop/CommandRegistry.swift) and shared [hotkey service](../Sources/Kebloop/HotkeyService.swift) support built-ins, quicklinks, Apple Shortcuts, apps, and a custom launcher key. Existing assignments are retained. Persistence, duplicate/system reservations, cancellation/resumption, unavailable reassignment rollback, and disabling bindings are tested. Native recorder/focus verification remains pending.


### 06 — Configuration export and import

- [ ] Complete
- **Scope:** Define a versioned configuration file for aliases, quicklinks, shortcuts, pins, and search/appearance preferences. Add export, import preview, validation, and explicit merge or replace behavior.
- **Acceptance:** Round-trip export/import preserves supported settings. Unknown versions and malformed files fail without partial writes. Conflicts and machine-specific paths/apps are shown before applying changes. Clipboard contents, credentials, caches, and usage history are excluded. Export a backup before replacing existing settings.
- **Dependencies:** 03–05 to cover the first milestone's settings.
- **Delivery (2026-10-12):** [Versioned configuration](../Sources/Kebloop/ConfigurationStore.swift) implements export, import preview, validation, merge/replace, backups, and activation rollback. Regression tests cover round trips, privacy exclusions, malformed templates/identifiers, unsupported versions, conflicts, backup creation, and no partial application. File-panel interaction remains unverified.


### 07 — Onboarding, command browsing, and help

- [ ] Complete
- **Scope:** Add Browse Commands, searchable in-app help, optional shortcut hints, and a short skippable first-run walkthrough. Explain login startup, clipboard recording, and optional permissions through explicit choices. Include examples and a way to replay onboarding.
- **Acceptance:** A new user can discover clipboard, quicklinks, emoji, settings, and the action menu without external documentation. Dismissing onboarding persists. Help reflects current shortcuts and feature availability. Upgrades retain existing user choices.
- **Dependencies:** 02 and 05. Add new commands to help as they ship.
- **Delivery (2026-10-12):** [Searchable help and skippable onboarding](../Sources/Kebloop/HelpView.swift) show live shortcut assignments, availability, examples, and optional hints. First-run login/clipboard/Siri choices are explicit; existing installations retain choices. Browse Commands opens actionable help and onboarding can be replayed. Native first-run and VoiceOver navigation require verification.


### 08 — Parameterized quicklinks and web search

- [x] Complete
- **Scope:** Extend quicklinks with a keyword and query placeholder, such as `gh kebloop` or `maps Warsaw`. Add configurable web-search templates and an explicit fallback search action for unmatched queries. Provide examples and template previews.
- **Acceptance:** Arguments with spaces, Unicode, and URL-sensitive characters are encoded correctly. Invalid templates and conflicting keywords produce feedback. Ordinary quicklinks remain compatible. Network destinations open only after an explicit action.
- **Dependencies:** 05 for stable command identities, 06 for portable templates, 07 for discovery.
- **Delivery (2026-10-12):** [Quicklink/web templates](../Sources/Kebloop/QuicklinkStore.swift) support keywords and encoded {query} arguments, backwards-compatible ordinary links, template previews, and configurable explicit fallback search. Unicode, spaces, URL-sensitive characters, legacy decoding, and keyword conflicts pass regression tests. Search never opens a network destination until an explicit action.


### 09 — Apple Shortcuts integration

- [ ] Complete
- **Scope:** Let users select Apple Shortcuts to expose as launcher commands, optionally pass text input, refresh their list, and assign launcher shortcuts. Explain required permissions when applicable.
- **Acceptance:** Selected shortcuts run with the expected input. Rename, deletion, cancellation, and execution failures are handled. A slow shortcut does not block search or keyboard input. Configurations on another Mac report missing shortcuts clearly.
- **Dependencies:** 05 and 07. Confirm supported macOS integration APIs before implementation.
- **Delivery (2026-10-12):** [Apple Shortcuts service](../Sources/Kebloop/AppleShortcutsService.swift) uses the macOS shortcuts CLI off the UI thread with UUID identities, selection, refresh, optional UTF-8 input, cancellation, errors, and command bindings. CLI list syntax was verified locally; injected-process tests cover input, failures, cancellation, rename, and missing shortcuts. Real user shortcut execution/permission prompts remain unverified to avoid running personal automations.


### 10 — Work and Personal profiles

- [ ] Complete
- **Scope:** Add named profiles containing links, aliases, command bindings, pins, and search/appearance settings. Support manual profile switching and profile-aware export/import. Keep launch-at-login and privacy controls global initially.
- **Acceptance:** Switching profiles updates results and shortcut registrations together, with rollback if registration fails. The active profile is visible. Users can duplicate, rename, export, and delete profiles without losing the final usable profile. Clipboard history and credentials are never duplicated into profiles.
- **Dependencies:** 05–06. Automatic context switching is a later enhancement, not part of this chunk.
- **Delivery (2026-10-12):** [Profiles](../Sources/Kebloop/ConfigurationStore.swift) capture portable settings and support create/duplicate/rename/delete/switch/export. The launcher displays the active profile, registrations are refreshed together, and activation failures roll back. Tests cover profile switching rollback and final-profile protection. Login/privacy/clipboard/history stay global. Native profile-management interaction remains unverified.


### 11 — Clipboard retention and privacy controls

- [ ] Complete
- **Scope:** Add pinned entries, configurable age/count retention, exclusions by source app, and a timed recording pause. Define whether pinned entries expire; make the policy visible. Extend existing sensitive-content exclusions.
- **Acceptance:** Expired entries are removed from memory and persisted storage. Pauses survive relaunch until their deadline. Excluded source apps are not recorded where attribution is reliable; document attribution limits. Clear History explicitly explains whether it includes pinned items. Existing history migrates safely.
- **Dependencies:** 02 for pin actions, 07 for privacy explanations. Keep these controls global across profiles.

### 12 — Snippets and reusable text

- [ ] Complete
- **Scope:** Add named, searchable text snippets with explicit placeholders, preview, copy, and optional insertion. Start with launcher-triggered snippets; do not add global keystroke monitoring for automatic expansion.
- **Acceptance:** Placeholder values render predictably and cancel safely. Snippets export/import with configuration. Copy works without additional permissions. Optional insertion explains its permission needs and retains a copy fallback.
- **Dependencies:** 05–07. Reuse input conventions from 08 where useful.

### 13 — Unit conversion and date calculations

- [ ] Complete
- **Scope:** Extend inline calculation with a documented set of length, mass, temperature, and data units, plus date differences and date addition. Support locale-aware input and output without changing existing expression semantics unexpectedly.
- **Acceptance:** Tests cover unit aliases, incompatible dimensions, temperature offsets, decimal commas, ambiguous dates, time zones, and daylight-saving transitions. Incomplete input stays quiet; valid output remains copyable. Document supported syntax. Currency conversion requires a separate rate-source/cache/offline design and is deferred.
- **Dependencies:** None; can run independently of UI work.

### 14 — Localization and keyboard-layout support

- [ ] Complete
- **Scope:** Extract user-facing strings, then add English and Polish as the initial languages. Add localized command aliases and help examples. Audit input-method composition, non-US keyboard layouts, shortcut labels, and locale formatting.
- **Acceptance:** Commands remain searchable by stable English names and localized aliases. Input-method composition does not trigger actions prematurely. Longer translated strings fit. Shortcuts display and record correctly on tested layouts. Add a documented process for future community translations.
- **Dependencies:** 05 and 07. Coordinate conversion grammar with 13; add right-to-left layout verification before shipping a right-to-left language.

### 15 — Images and rich text in clipboard history

- [ ] Complete
- **Scope:** Add image thumbnails and rich-text preservation alongside plain-text entries. Introduce byte-based storage limits, lazy previews, format-aware copying, and migration/cleanup for attachment files.
- **Acceptance:** Copying restores appropriate pasteboard formats. Large images cannot exhaust storage or stall search. Sensitive-type exclusions apply to every format. Deleting, clearing, and expiring entries removes associated files. Test persistence and recovery from missing/corrupt attachments.
- **Dependencies:** 11. This is a separate chunk because its storage model is larger than text-only history.

### 16 — User script commands

- [ ] Complete
- **Scope:** Add user-selected scripts with metadata (stable ID, title, description, arguments, executable/runtime), launcher invocation, output preview, cancellation, timeouts, and actionable errors. Provide templates and a command management view.
- **Acceptance:** Scripts run off the UI thread; output and runtime are bounded. Pass arguments as process arguments, not interpolated shell source. Missing runtimes, nonzero exits, and cancellation are handled. Users review imported scripts before enabling execution. Importing configuration never runs code. Secrets stay out of configuration exports and logs.
- **Dependencies:** 02, 05–07. Document that local scripts execute with the user's privileges; a metadata permission declaration is not a sandbox.

### 17 — Small extension API

- [ ] Complete
- **Scope:** Use lessons from scripts and Shortcuts to define a versioned interface for search results, actions, preferences, and native list/detail views. Add an extension manifest, lifecycle rules, developer examples, and enable/disable/remove controls.
- **Acceptance:** A sample extension can contribute results and actions without changing launcher code. Crashes and slow extensions do not freeze built-in search. Compatibility errors are clear. Define isolation, trust, file/network access, and credential storage before shipping third-party execution. Verify that any claimed permission restrictions are actually enforced.
- **Dependencies:** 09 and 16, with real workflow feedback. Choose the runtime in a design checkpoint; do not commit to a JavaScript/React runtime prematurely. A public marketplace is separate future work.

### 18 — Signed and notarized distribution

- [ ] Complete
- **Scope:** Produce a repeatable release build, sign with a distribution identity, notarize and staple the artifact, and publish a versioned download with installation instructions. Verify supported Intel/Apple Silicon packaging and permission persistence across upgrades.
- **Acceptance:** A clean Mac can install and open the downloaded build without developer tools. Signature and notarization checks pass. Installing over an older version preserves preferences and history. Publish the tested architecture/macOS support matrix and release notes.
- **Dependencies:** Apple Developer credentials and a chosen download destination. Build preparation and documentation can proceed before credentials are available; publication requires an explicit release instruction.

### 19 — Built-in updates

- [ ] Complete
- **Scope:** Select and integrate a maintained macOS update mechanism, add manual Check for Updates, optional automatic checks, signed update metadata/artifacts, and release notes. Decide how to host the update feed.
- **Acceptance:** Valid updates install and preserve configuration. Invalid signatures, broken downloads, offline use, and interrupted updates leave the installed app usable. Automatic checks respect the user's preference. Test an actual upgrade between two signed builds.
- **Dependencies:** 18 and a release hosting/update-feed decision. Assess current updater options and requirements at implementation time.

## Coordination and validation

- Root coordination owns command/action identifiers, configuration schema, ranking policy, permission UX, shared architecture, and final integration review.
- Independent work can be split by ownership: core conversion logic (13), localization preparation (14), and release tooling (18) can proceed alongside launcher feature work. Avoid concurrent edits to the launcher/settings controllers without an agreed integration boundary.
- For each chunk, add meaningful regression coverage for persistence, parsing, ranking, lifecycle, or execution behavior as applicable. Use manual/native UI checks for focus, VoiceOver, shortcuts, layout, and Spaces. Do not substitute unit tests for device verification.
- Run the existing release test suite for code changes and profile search/open responsiveness when changing the input path, result rendering, indexing, or background execution. Compare with recorded baselines in [performance documentation](performance.md).
- Update [usage documentation](usage.md) alongside delivered behavior, and include migration, permission, and offline behavior where relevant.
- Keep a short delivery note under a completed chunk with implementation links, validation performed, and any limitations.

## Milestones 1–2 validation

The release test suite passes 96 tests (two opt-in timing tests skipped). The separately enabled AppKit performance profile passes and the release bundle builds with signature verification. See [performance results](performance.md#milestones-12-follow-up). Acceptance checkboxes for chunks needing direct UI/device checks remain open: the native automation connection timed out twice, so tests are not being substituted for VoiceOver, focus, display, Spaces, and real permission-prompt verification. No later milestone features were included.

## Starting point

Milestones 1–2 have implementation and regression coverage. Complete the remaining native acceptance checks listed in their delivery notes before marking the outstanding checkboxes. Then continue with milestone 3; reassess priorities based on actual use.
