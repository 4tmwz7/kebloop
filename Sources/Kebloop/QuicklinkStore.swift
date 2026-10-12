import Foundation
import Combine

struct Quicklink: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var target: String
    var keyword: String = ""
    var url: URL? { resolvedURL(argument: "") }
    init(id: String, name: String, target: String, keyword: String = "") {
        self.id = id; self.name = name; self.target = target; self.keyword = keyword
    }
    enum CodingKeys: String, CodingKey { case id, name, target, keyword }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        target = try values.decode(String.self, forKey: .target)
        keyword = try values.decodeIfPresent(String.self, forKey: .keyword) ?? ""
    }
    func resolvedURL(argument: String) -> URL? {
        Self.destination(target, argument: argument)
    }
    static func destination(_ target: String, argument: String = "") -> URL? {
        var value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("{query}") {
            guard !value.hasPrefix("/") && !value.hasPrefix("~/"), let encoded = argument.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return nil }
            // Placeholders must be in a path, query, or fragment, never in the host.
            guard let components = URLComponents(string: value.replacingOccurrences(of: "{query}", with: "KEBLOOPQUERY")), !(components.host?.contains("KEBLOOPQUERY") ?? false) else { return nil }
            value = value.replacingOccurrences(of: "{query}", with: encoded)
        }
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }
        guard !value.contains("{") && !value.contains("}") else { return nil }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

struct WebSearchTemplate: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var keyword: String
    var target: String
    func resolvedURL(argument: String) -> URL? { Quicklink.destination(target, argument: argument) }
}

@MainActor
final class QuicklinkStore: ObservableObject {
    @Published private(set) var links: [Quicklink] = []
    @Published private(set) var webSearches: [WebSearchTemplate] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; reload() }
    func reload() {
        links = (defaults.data(forKey: "quicklinks").flatMap { try? JSONDecoder().decode([Quicklink].self, from: $0) } ?? []).filter { $0.url != nil }
        if let data = defaults.data(forKey: "webSearches") {
            webSearches = (try? JSONDecoder().decode([WebSearchTemplate].self, from: data)) ?? []
        } else {
            webSearches = [WebSearchTemplate(id: "duckduckgo", name: "DuckDuckGo", keyword: "web", target: "https://duckduckgo.com/?q={query}")]
        }
    }
    func resolve(query: String) -> (link: Quicklink, argument: String)? {
        let parts = query.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let keyword = parts.first else { return nil }
        let argument = parts.count > 1 ? String(parts[1]) : ""
        if let link = links.first(where: { !$0.keyword.isEmpty && $0.keyword.lowercased() == keyword.lowercased() }) { return (link, argument) }
        if let search = webSearches.first(where: { $0.keyword.lowercased() == keyword.lowercased() }) {
            return (Quicklink(id: "web:\(search.id)", name: search.name, target: search.target, keyword: search.keyword), argument)
        }
        return nil
    }
    func fallbackURL(query: String) -> URL? { webSearches.first?.resolvedURL(argument: query) }
    @discardableResult
    func save(id: String? = nil, name: String, target: String, keyword: String = "") -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return "Enter a name for this quicklink." }
        guard Quicklink.destination(target) != nil else { return "Use an https:// or http:// URL, or an absolute / or ~/ file path. Templates use {query}." }
        if let error = keywordError(keyword, excluding: id) { return error }
        let link = Quicklink(id: id ?? UUID().uuidString, name: name, target: target, keyword: keyword)
        if let offset = links.firstIndex(where: { $0.id == link.id }) { links[offset] = link } else { links.append(link) }
        persist()
        return nil
    }
    @discardableResult
    func saveWebSearch(id: String? = nil, name: String, keyword: String, target: String) -> String? {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a search name." }
        guard !keyword.isEmpty else { return "Enter a search keyword." }
        guard target.contains("{query}"), let url = Quicklink.destination(target), !url.isFileURL else { return "Use an http:// or https:// template containing {query}." }
        if let error = keywordError(keyword, excluding: id) { return error }
        let search = WebSearchTemplate(id: id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), keyword: keyword, target: target.trimmingCharacters(in: .whitespacesAndNewlines))
        if let offset = webSearches.firstIndex(where: { $0.id == search.id }) { webSearches[offset] = search } else { webSearches.append(search) }
        persist(); return nil
    }
    func remove(id: String) { links.removeAll { $0.id == id }; persist() }
    func removeWebSearch(id: String) { webSearches.removeAll { $0.id == id }; persist() }
    private func keywordError(_ keyword: String, excluding id: String?) -> String? {
        guard !keyword.isEmpty else { return nil }
        guard !keyword.contains(where: { $0.isWhitespace }) else { return "Keywords must be a single word." }
        if links.contains(where: { $0.id != id && $0.keyword.lowercased() == keyword }) || webSearches.contains(where: { $0.id != id && $0.keyword.lowercased() == keyword }) { return "This keyword is already assigned." }
        return nil
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(links) { defaults.set(data, forKey: "quicklinks") }
        if let data = try? JSONEncoder().encode(webSearches) { defaults.set(data, forKey: "webSearches") }
    }
}
