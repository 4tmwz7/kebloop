import Foundation
import Combine

struct ExtensionPreference: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var defaultValue: String
}
struct ExtensionManifest: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var description: String
    var apiVersion: Int
    var executable: String
    var arguments: [String]
    var preferences: [ExtensionPreference]
    var enabled: Bool = false
    var commandID: String { "extension:\(id)" }
    func validate() throws {
        guard apiVersion == 1 else { throw AutomationFailure.invalid("Unsupported extension API version. Kebloop supports version 1.") }
        guard !id.isEmpty, !name.isEmpty, executable.hasPrefix("/"), !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }), Set(preferences.map(\.id)).count == preferences.count else { throw AutomationFailure.invalid("Invalid extension manifest. Check its identifier, executable and preferences.") }
    }
}
struct ExtensionAction: Codable, Identifiable, Hashable {
    let id: String
    let title: String
}
struct ExtensionResult: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let detail: String?
    let actions: [ExtensionAction]
}
struct ExtensionRequest: Codable {
    let apiVersion: Int
    let operation: String
    let query: String
    let resultID: String?
    let actionID: String?
    let preferences: [String: String]
}
struct ExtensionResponse: Codable {
    let apiVersion: Int
    let results: [ExtensionResult]
    let message: String?
    func validate() throws {
        guard apiVersion == 1 else { throw AutomationFailure.invalid("The extension returned an incompatible API version.") }
        guard results.count <= 100, Set(results.map(\.id)).count == results.count, results.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && $0.actions.count <= 20 && Set($0.actions.map(\.id)).count == $0.actions.count && $0.actions.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }) }) else { throw AutomationFailure.invalid("The extension returned invalid results or actions.") }
    }
}

@MainActor
final class ExtensionStore: ObservableObject {
    @Published private(set) var manifests: [ExtensionManifest] = []
    @Published private(set) var results: [ExtensionResult] = []
    @Published private(set) var activeID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private var process: AutomationProcess?
    private var generation = UUID()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; reload() }
    func reload() {
        cancel(); results = []; activeID = nil; error = nil; message = nil
        manifests = (defaults.data(forKey: "extensionManifests").flatMap { try? JSONDecoder().decode([ExtensionManifest].self, from: $0) } ?? []).filter { (try? $0.validate()) != nil }
    }
    func install(_ manifest: ExtensionManifest) throws {
        try manifest.validate()
        var manifest = manifest; manifest.enabled = false
        if let index = manifests.firstIndex(where: { $0.id == manifest.id }) { if activeID == manifest.id { cancel(); results = []; activeID = nil; error = nil; message = nil }; manifests[index] = manifest }
        else { manifests.append(manifest) }
        persist()
    }
    func setEnabled(id: String, enabled: Bool) {
        guard let index = manifests.firstIndex(where: { $0.id == id }) else { return }
        if !enabled, activeID == id { cancel(); results = []; activeID = nil; error = nil; message = nil }
        manifests[index].enabled = enabled; persist()
    }
    func remove(id: String) {
        if activeID == id { cancel(); results = []; activeID = nil; error = nil; message = nil }
        manifests.removeAll { $0.id == id }
        defaults.removeObject(forKey: "extensionPreferences.\(id)"); persist()
    }
    func preferences(id: String) -> [String: String] {
        guard let manifest = manifests.first(where: { $0.id == id }) else { return [:] }
        let saved = defaults.dictionary(forKey: "extensionPreferences.\(id)") as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: manifest.preferences.map { ($0.id, saved[$0.id] ?? $0.defaultValue) })
    }
    func setPreference(extensionID: String, key: String, value: String) {
        guard manifests.first(where: { $0.id == extensionID })?.preferences.contains(where: { $0.id == key }) == true else { return }
        var values = preferences(id: extensionID); values[key] = value
        defaults.set(values, forKey: "extensionPreferences.\(extensionID)")
    }
    func search(id: String, query: String) { invoke(id: id, operation: "search", query: query) }
    func perform(id: String, resultID: String, actionID: String) {
        guard activeID == id, results.contains(where: { $0.id == resultID && $0.actions.contains(where: { $0.id == actionID }) }) else { error = "This extension action is no longer available."; return }
        invoke(id: id, operation: "action", resultID: resultID, actionID: actionID)
    }
    private func invoke(id: String, operation: String, query: String = "", resultID: String? = nil, actionID: String? = nil) {
        guard let manifest = manifests.first(where: { $0.id == id && $0.enabled }) else { error = "Review and enable this extension in Settings first."; return }
        cancel()
        let runner = AutomationProcess(), token = UUID(); generation = token; process = runner
        let request = ExtensionRequest(apiVersion: 1, operation: operation, query: query, resultID: resultID, actionID: actionID, preferences: preferences(id: id))
        activeID = id; isRunning = true; error = nil; message = nil
        if operation == "search" { results = [] }
        Task {
            let response = await Task.detached { Result { () throws -> ExtensionResponse in
                let input = try JSONEncoder().encode(request)
                let output = try runner.execute(executable: manifest.executable, arguments: manifest.arguments, input: input, timeout: 5)
                guard let data = output.stdout.data(using: .utf8) else { throw AutomationFailure.invalid("Extension output must be UTF-8 JSON.") }
                let value: ExtensionResponse
                do { value = try JSONDecoder().decode(ExtensionResponse.self, from: data) } catch { throw AutomationFailure.invalid("Extension returned malformed JSON. Check the version 1 response format.") }
                try value.validate(); return value
            } }.value
            guard generation == token else { return }
            isRunning = false; process = nil
            switch response { case .success(let value): results = value.results; message = value.message
            case .failure(let failure): error = failure.localizedDescription; results = [] }
        }
    }
    func cancel() { generation = UUID(); process?.cancel(); process = nil; isRunning = false }
    private func persist() { if let data = try? JSONEncoder().encode(manifests) { defaults.set(data, forKey: "extensionManifests") } }
}
