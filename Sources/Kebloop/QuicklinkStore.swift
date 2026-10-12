import Foundation
import Combine

struct Quicklink: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var target: String
    var url: URL? { Self.destination(target) }

    static func destination(_ target: String) -> URL? {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

@MainActor
final class QuicklinkStore: ObservableObject {
    @Published private(set) var links: [Quicklink]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        links = defaults.data(forKey: "quicklinks").flatMap { try? JSONDecoder().decode([Quicklink].self, from: $0) } ?? []
        links = links.filter { $0.url != nil }
    }
    @discardableResult
    func save(id: String? = nil, name: String, target: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a name for this quicklink." }
        guard Quicklink.destination(target) != nil else { return "Use an https:// or http:// URL, or an absolute / or ~/ file path." }
        let link = Quicklink(id: id ?? UUID().uuidString, name: name, target: target)
        if let offset = links.firstIndex(where: { $0.id == link.id }) { links[offset] = link }
        else { links.append(link) }
        persist()
        return nil
    }
    func remove(id: String) {
        links.removeAll { $0.id == id }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(links) { defaults.set(data, forKey: "quicklinks") }
    }
}
