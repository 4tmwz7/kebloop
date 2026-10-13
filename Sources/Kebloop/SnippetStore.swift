import AppKit
import Combine

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var template: String
    /// A space-terminated trigger for optional automatic expansion.
    /// Optional so snippets in existing configuration files continue to decode.
    var keyword: String? = nil

    private static let tokenPattern = #"\{([A-Za-z][A-Za-z0-9_]*)(?::([^{}]*))?\}"#
    private static let dynamicNames: Set<String> = ["date", "time", "clipboard"]

    private var tokens: [(range: NSRange, name: String, defaultValue: String?)] {
        guard let regex = try? NSRegularExpression(pattern: Self.tokenPattern) else { return [] }
        let source = template as NSString
        return regex.matches(in: template, range: NSRange(location: 0, length: source.length)).map { match in
            (match.range, source.substring(with: match.range(at: 1)),
             match.range(at: 2).location == NSNotFound ? nil : source.substring(with: match.range(at: 2)))
        }
    }

    var placeholders: [String] {
        var names: [String] = []
        for token in tokens where !Self.dynamicNames.contains(token.name) {
            if !names.contains(token.name) { names.append(token.name) }
        }
        return names
    }

    var placeholderDefaults: [String: String] {
        var defaults: [String: String] = [:]
        for token in tokens where !Self.dynamicNames.contains(token.name) {
            if defaults[token.name] == nil, let value = token.defaultValue { defaults[token.name] = value }
        }
        return defaults
    }

    var canExpandAutomatically: Bool {
        placeholders.allSatisfy { placeholderDefaults[$0] != nil }
    }

    func render(
        values: [String: String],
        date: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        clipboardText: String? = nil
    ) throws -> String {
        let defaults = placeholderDefaults
        guard placeholders.allSatisfy({ values[$0] != nil || defaults[$0] != nil }) else {
            throw ConfigurationError.invalid("Fill every snippet placeholder.")
        }
        for name in Self.dynamicNames where tokens.contains(where: { $0.name == name && $0.defaultValue != nil }) {
            throw ConfigurationError.invalid("Dynamic snippet values cannot have defaults.")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let renderedDate = dateFormatter.string(from: date)
        dateFormatter.dateStyle = .none
        dateFormatter.timeStyle = .short
        let renderedTime = dateFormatter.string(from: date)
        let clipboard = clipboardText ?? NSPasteboard.general.string(forType: .string) ?? ""
        var output = template
        for token in tokens.reversed() {
            let value: String
            switch token.name {
            case "date": value = renderedDate
            case "time": value = renderedTime
            case "clipboard": value = clipboard
            default: value = values[token.name] ?? defaults[token.name] ?? token.defaultValue ?? ""
            }
            output = (output as NSString).replacingCharacters(in: token.range, with: value)
        }
        return output
    }

    func validate() throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200, !template.isEmpty, template.utf8.count <= 100_000 else { throw ConfigurationError.invalid("A snippet needs a name and text (up to 100 KB).") }
        if let keyword {
            guard !keyword.isEmpty, keyword.utf8.count <= 64,
                  keyword.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
                throw ConfigurationError.invalid("A snippet keyword must use 1–64 printable ASCII characters with no spaces.")
            }
        }
        let defaultsByName = Dictionary(grouping: tokens.filter { !Self.dynamicNames.contains($0.name) && $0.defaultValue != nil }, by: \.name)
        for (name, defaults) in defaultsByName {
            guard Set(defaults.compactMap(\.defaultValue)).count <= 1 else {
                throw ConfigurationError.invalid("Repeated placeholder {\(name)} must use the same default value.")
            }
        }
        guard !tokens.contains(where: { Self.dynamicNames.contains($0.name) && $0.defaultValue != nil }) else {
            throw ConfigurationError.invalid("Dynamic snippet values cannot have defaults.")
        }
    }

    static func validateUniqueKeywords(_ snippets: [Snippet]) throws {
        var seen: Set<String> = []
        for keyword in snippets.compactMap(\.keyword) {
            let normalized = keyword.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(normalized).inserted else {
                throw ConfigurationError.invalid("Snippet keywords must be unique, ignoring letter case.")
            }
        }
    }
}

@MainActor final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; reload() }
    func reload() {
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        SnippetExpansionService.shared.resetForSnippetChanges()
    }
    func save(id: String? = nil, name: String, template: String, keyword: String? = nil) throws {
        let cleanedKeyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = Snippet(id: id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), template: template, keyword: cleanedKeyword?.isEmpty == true ? nil : cleanedKeyword)
        try snippet.validate()
        var updated = snippets
        if let index = updated.firstIndex(where: { $0.id == snippet.id }) { updated[index] = snippet } else { updated.append(snippet) }
        try Snippet.validateUniqueKeywords(updated)
        snippets = updated
        SnippetExpansionService.shared.resetForSnippetChanges()
        persist()
    }
    func remove(id: String) {
        snippets.removeAll { $0.id == id }
        SnippetExpansionService.shared.resetForSnippetChanges()
        persist()
    }
    private func persist() { if let data = try? JSONEncoder().encode(snippets) { defaults.set(data, forKey: "snippets") } }
}
