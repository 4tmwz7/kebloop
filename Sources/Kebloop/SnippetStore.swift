import AppKit
import Combine

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var template: String
    var placeholders: [String] {
        let regex = try! NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#)
        let source = template as NSString
        var names: [String] = []
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1))
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
    func render(values: [String: String]) throws -> String {
        guard placeholders.allSatisfy({ values[$0] != nil }) else { throw ConfigurationError.invalid("Fill every snippet placeholder.") }
        // Replace only original tokens: values containing braces remain literal.
        let regex = try! NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#)
        let source = template as NSString
        var output = template
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1))
            output = (output as NSString).replacingCharacters(in: match.range, with: values[name] ?? "")
        }
        return output
    }
    func validate() throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200, !template.isEmpty, template.utf8.count <= 100_000 else { throw ConfigurationError.invalid("A snippet needs a name and text (up to 100 KB).") }
    }
}

@MainActor final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; reload() }
    func reload() { snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? [] }
    func save(id: String? = nil, name: String, template: String) throws {
        let snippet = Snippet(id: id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), template: template)
        try snippet.validate()
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = snippet } else { snippets.append(snippet) }
        persist()
    }
    func remove(id: String) { snippets.removeAll { $0.id == id }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(snippets) { defaults.set(data, forKey: "snippets") } }
}
