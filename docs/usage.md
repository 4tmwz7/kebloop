# Kebloop usage guide

For build and installation instructions, see the [README](../README.md#build-and-install).

## Using Kebloop

- **Option-Space** opens or closes the launcher by default (your saved shortcut is retained).
- Type an app name, alias, quicklink, or filename. Apps and commands appear immediately; indexed files appear underneath. **Up/Down** selects a result; **Return** opens it or brings it forward. The launcher hides as soon as an external action is accepted, without waiting for the destination app to finish launching. Failed launches restore the query with an error unless you have already opened a new launcher session.
- Type math in the same field. Results appear immediately; **Return** copies the answer and closes the launcher.
- **Command-K**, the **Actions** button, or right-clicking a result opens its custom action panel. **Up/Down** selects an action and **Return** runs it; **Escape** closes the panel while keeping your search and selected result.
- **Escape** or an outside click closes the launcher.
- **Command-comma** opens settings. The menu-bar icon also opens the launcher, settings, and a manual app refresh.
- Settings offer Option-Space, Control-Space, Command-Shift-Space, Command-Space, or a recorded launcher shortcut, plus optional launch at login. System shortcuts may need to be reassigned before using the same combination.

## Commands and settings

Type a command name in the launcher, then press Return:

| Command | Behavior |
| --- | --- |
| Clipboard History | Search up to 200 recent text entries; Return copies one. Trash removes an item; Clear… removes all after confirmation. |
| Quicklinks | Browse saved links. Links also appear directly in root search by name. |
| Web Search | Search the web using a configured template; the destination opens only after you choose the result. |
| Apple Shortcuts | Browse the shortcuts selected in Settings → Apple Shortcuts. |
| Profiles | View and switch saved settings profiles. |
| Emoji & Symbols | Open the searchable emoji grid with categories and recents; click or Return copies an emoji. Arrow keys navigate. |
| Browse Commands / Help | Search built-in commands, saved quicklinks, selected Apple Shortcuts, current shortcut assignments, and feature availability. |
| Welcome to Kebloop | Replay the skippable first-run choices for login startup, clipboard history, and optional Siri access. |
| Open Settings | Configure Kebloop without using its menu-bar icon. |
| Shut Down… | Type `shutdown`, `power off`, or `turn off`, then Return to open the macOS shutdown confirmation. Confirm there to turn off your Mac, or cancel. |

Within clipboard and quicklink search, Escape or the back button returns to root search. Lists scroll; arrow navigation keeps the selected row visible.

**Quicklinks:** Settings → Quicklinks creates, edits, and removes named `https://` or `http://` URLs and absolute or `~/` file/folder paths. An optional one-word keyword accepts a query after it; templates substitute percent-encoded text for `{query}`. Unsupported schemes, invalid templates, duplicate keywords, and empty names are rejected.

**Aliases:** Settings → Aliases assigns an alternate search name to an app. Exact aliases outrank exact app names: Ghostty with alias `terminal` appears above Terminal. Aliases persist and duplicate aliases are rejected.

**App shortcuts:** Settings → App Shortcuts lets you search an installed app and record a physical key combination containing Command, Option, or Control. Assignments persist across restarts. Duplicate assignments, launcher conflicts, and unavailable system shortcuts produce feedback. Recording temporarily releases global shortcuts and restores them when finished or cancelled.

**Command shortcuts:** Settings → Command Shortcuts assigns global shortcuts to built-in commands, saved quicklinks, and selected Apple Shortcuts. These use the same conflict checks as app shortcuts. Removing a quicklink or deselecting an Apple Shortcut removes its command binding. Settings → Help shows the current assignments; its shortcut-hints choice controls the hints shown beside launcher actions.

**Search and appearance:** Settings → Search enables or disables app, file, link, and built-in-command results; chooses searchable folders; excludes folders by path; hides selected apps; manages pinned favorites; and selects the empty-launcher list. Folder exclusions respect path boundaries, so excluding `~/Documents/Private` does not hide `~/Documents/Privateer`. Reset Search Settings restores search defaults and removes pinned favorites. Settings → Appearance selects system, light, or dark appearance; text size; panel width; row density; transparency; and pointer, active-window, or selected-display placement. Reduced transparency follows the macOS accessibility preference, and an unavailable selected display falls back to the pointer display.

**Parameterized quicklinks and web search:** Settings → Quicklinks accepts an optional one-word keyword. Type the keyword followed by text to pass an argument, such as `gh kebloop`; `{query}` in a URL template is replaced with percent-encoded text. Web search templates require an HTTP or HTTPS URL containing `{query}` and show a preview in settings. Unmatched text offers a web-search result only when a valid template is configured; opening the destination requires selecting that result.

**Apple Shortcuts:** Settings → Apple Shortcuts refreshes the shortcuts available on this Mac and lets you choose which appear in Kebloop. You can run a selected shortcut with optional text input; a shortcut can be cancelled from settings. Kebloop uses macOS's `shortcuts` command-line tool. macOS may request permission on first use, and shortcuts missing on another Mac are reported as unavailable.

**Profiles and portable configuration:** Settings → Profiles creates, duplicates, renames, switches, exports, and deletes profiles. Each profile contains links, aliases, command bindings, pins, and search and appearance preferences; at least one profile is always kept. Login startup and clipboard privacy remain global. Settings → Configuration exports configuration as JSON, or imports it with a preview and explicit merge or replace choice. Replace saves a backup first. Clipboard contents, credentials, caches, and usage history are excluded. The preview reports malformed or unsupported files, conflicts, unavailable paths or apps, and Apple Shortcut names that may be missing on another Mac.

**First run and help:** The short welcome screen lets you choose login startup and clipboard recording, and offers Accessibility access for direct Siri text submission as an optional choice. Skip or finish the walkthrough to dismiss it; type `welcome` or open Settings → Help to replay it or browse commands. Help searches current shortcut assignments and selected links, and reflects disabled clipboard recording or an empty Apple Shortcuts selection. You can hide shortcut hints there without removing your assignments.

**Clipboard:** Text copied after Kebloop starts is recorded locally; the existing clipboard is not ingested on startup. Duplicate text moves to the front, and entries larger than 100 KB are skipped. Concealed, transient, autogenerated, and password-marked clipboard content is excluded. Settings → Clipboard pauses recording or clears saved history. Use a row’s trash button or Command-Backspace to remove an item. Clear… or Command-Shift-Backspace opens a confirmation to clear all saved history. Images and rich-text history are not included in this version.

**Files:** Filename search runs directly from root search, with apps above files and no separate command to open. A 35 ms debounce starts Spotlight searches; cached query snapshots appear immediately while narrowing or revisiting a query, and new results stream during gathering. Hidden paths, app package contents, `~/Library`, and `node_modules` are excluded. Temporary directories, editor backup/swap files, and partial downloads are also excluded. Git repositories are checked against their `.gitignore` rules before either cached or fresh results appear, including nested rules, negations, worktrees, and configured excludes. This uses local `/usr/bin/git` (provided by Xcode or Command Line Tools); tracked files follow Git’s own ignore semantics. Checks run on a worker queue and rule changes apply on the next search. Exact names and prefixes rank before substring matches, with a boost for Documents/Desktop/Downloads/Public. Results depend on Spotlight indexing and macOS access restrictions. This is filename search, not full-content search; the service keeps up to 40 results per query and root search displays up to 12.

## AI handoff

Settings → General → AI provider selects **OpenAI (ChatGPT)**, **Claude**, or **Local (Siri)**. Type a query in root search and press **Tab**, or click the compact Ask button. Your selection persists across restarts.

ChatGPT opens with your query filled in using a prompt-bearing URL. Claude also receives the query in its URL; signing in may be required. Siri opens a new conversation, fills the native query field, and submits it directly. Enable Siri and Type to Siri, then allow Kebloop under System Settings → Privacy & Security → Device Control and Data Access (Accessibility on older macOS) once. Development builds use an available Apple Development signing identity to preserve grants across rebuilds; set `KEBLOOP_SIGNING_IDENTITY` to choose one. Without a signing identity, the ad-hoc fallback requires renewing the grant after each rebuild. No API keys are required.

Finder is indexed explicitly from CoreServices, alongside the user-facing CoreServices applications, so it appears in app search.

AI handoff text is marked transient so Kebloop does not add it to clipboard history. Blank queries and modified Tab shortcuts keep their normal behavior. If a destination fails to open, the launcher restores the query and shows an error.

## Calculator

Examples: `2*(3+4)`, `2^10`, `sqrt(81)`, `abs(-2)`, `round(2.6)`, `15% of 200`, `20% off 80`.

Supports `+ - * / ^`, parentheses, unary signs, scientific notation, `pi`, `e`, and decimal commas or dots. Powers associate right to left; `-2^2` is `-4`. `%` is a fraction: `200 + 10%` is `200.1`; use `10% of 200` for `20`. Functions take one argument. Thousands grouping, currencies, units, and dates are outside the initial calculator grammar.

Calculations use Double and display up to 16 significant digits with insignificant floating-point noise suppressed. Clipboard output uses the same ungrouped decimal-dot representation. Expression/token/depth limits bound evaluation; unfinished expressions stay quiet.

The panel uses native Liquid Glass on macOS 26+, with interactive glass on macOS 27. Older supported releases use a native popover material. The launcher has no branding or keybinding footer.

**Background lifecycle:** Command-Q hides Kebloop’s interface without quitting. Closing all windows leaves it running in the menu bar. The welcome screen asks whether to launch at login; macOS may require approval in System Settings → General → Login Items. An explicit menu-bar Quit command remains available, and system shutdown/logout can terminate the app normally.

## App discovery and storage

Scans `/Applications`, `/System/Applications`, `~/Applications`, and the system Cryptex application directory (Safari), including organizational subfolders. App bundles are not traversed for embedded helpers; hidden and background-only apps are excluded. Settings can hide chosen applications from launcher results. Cached results appear immediately; scans run in the background on startup, each launcher opening, every five minutes, and manual refresh. Native workspace icons are cached directly and prewarmed in small yielded batches; visible icons take priority.

Search matches exact names, prefixes, word prefixes, and fuzzy subsequences, with a small usage boost. File results are limited to the folders selected in Settings → Search, then filtered by user exclusions and built-in temporary and package rules. App metadata is cached in `~/Library/Caches/Kebloop/application-index.json`; shortcut preferences, profiles, app bindings, aliases, quicklinks, emoji recents, and launch counts use UserDefaults. Clipboard text history is stored in `~/Library/Application Support/Kebloop/clipboard-history.json` with owner-only permissions. No Accessibility permission is needed for local search, clipboard, links, or app shortcuts; direct Siri text submission requests it only if chosen.

## Verification

Release XCTest coverage checks matching/ranking, duplicate names, calculator grammar, invalid input, precision, emoji search, quicklink validation/persistence, clipboard limits/deduplication/privacy/persistence, file-query cancellation/caching/ranking, alias priority/persistence, clipboard removal, Carbon shortcut event routing, and AI provider persistence/clipboard handoff/target selection. A synthetic 1,000-app ranking benchmark averaged approximately 9 ms on the development Mac. This measures ranking, not full input-to-render latency or parity with Raycast.

Native UI smoke checks covered app/calculator workflows, Settings search, creating and opening a quicklink, recording/copying clipboard entries, finding an indexed file, emoji search/copy, and the app shortcut recorder. App-scoped UI automation does not deliver system-wide Carbon hotkey events, so physical keyboard invocation of global shortcuts needs a manual check; native registration and Carbon event-routing tests pass. Multiple displays, full-screen Spaces, VoiceOver, login startup, and the under-100-ms open target still need broader device testing.

See [PLAN.md](../PLAN.md) for scope and acceptance targets.
