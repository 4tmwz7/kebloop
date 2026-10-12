# Localization coverage

The packaged English and Polish catalogs cover static launcher/settings/help/onboarding/snippet/automation presentation strings. English command aliases remain stable, with additive Polish aliases. macOS selects the resource language; resource keys and persisted command identifiers are independent.

`L` resolves the SwiftPM resource bundle. The app packaging script includes that bundle in Contents/Resources. New translation keys must be added to every supported catalog. Dynamic user content, external protocol fields, paths, shortcut hardware codes, and third-party accessibility identifiers are never translated. Some interpolated diagnostics and system-provided text remain in their source language.

Verification must distinguish automated catalog/parser checks from native checks: test Polish/non-US shortcut recording, IME marked text, VoiceOver speech, long Polish labels at large text sizes, and app language selection. Right-to-left support requires a separate layout audit. See usage.md for the community translation process.
