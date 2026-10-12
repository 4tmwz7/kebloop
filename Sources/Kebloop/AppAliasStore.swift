import Combine
import Foundation

@MainActor
final class AppAliasStore: ObservableObject {
    @Published private(set) var aliases: [String: String]

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumAliasLength = 100

    init(defaults: UserDefaults = .standard, storageKey: String = "appAliases") {
        self.defaults = defaults
        self.storageKey = storageKey

        let stored = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        var cleaned: [String: String] = [:]
        var usedAliases = Set<String>()
        for path in stored.keys.sorted() {
            guard let value = stored[path] else { continue }
            let alias = Self.trimmed(value)
            let normalized = Self.normalized(alias)
            guard !alias.isEmpty, alias.count <= maximumAliasLength,
                  !normalized.isEmpty, usedAliases.insert(normalized).inserted else { continue }
            cleaned[path] = alias
        }
        aliases = cleaned
        if cleaned != stored { defaults.set(cleaned, forKey: storageKey) }
    }

    func reload() {
        let restored = AppAliasStore(defaults: defaults, storageKey: storageKey)
        aliases = restored.aliases
    }

    func alias(for app: IndexedApplication) -> String? {
        aliases[app.path]
    }

    /// Saves one alias per app. An empty value removes the current alias.
    @discardableResult
    func save(alias rawAlias: String, for app: IndexedApplication) -> String? {
        let alias = Self.trimmed(rawAlias)
        guard !alias.isEmpty else {
            remove(for: app)
            return nil
        }
        guard alias.count <= maximumAliasLength else {
            return "Aliases can be up to \(maximumAliasLength) characters."
        }

        let normalized = Self.normalized(alias)
        guard !normalized.isEmpty else {
            return "Use at least one letter or number in the alias."
        }
        if aliases.contains(where: { $0.key != app.path && Self.normalized($0.value) == normalized }) {
            return "That alias is already assigned to another app."
        }

        aliases[app.path] = alias
        persist()
        return nil
    }

    func remove(for app: IndexedApplication) {
        aliases.removeValue(forKey: app.path)
        persist()
    }

    private func persist() {
        defaults.set(aliases, forKey: storageKey)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words.joined(separator: " ")
    }
}
