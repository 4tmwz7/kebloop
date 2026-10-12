import Foundation
import Combine

struct ScriptCommand: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var description: String
    var executable: String
    var arguments: [String]
    var timeout: Double = 10
    var enabled: Bool = false
    var commandID: String { "script:\(id)" }
    func validate() throws {
        guard !id.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, executable.hasPrefix("/"), !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }), timeout.isFinite, timeout > 0, timeout <= 300 else { throw AutomationFailure.invalid("Provide a title, absolute executable path, valid arguments, and a timeout from 0 to 300 seconds.") }
    }
}

@MainActor
final class ScriptCommandStore: ObservableObject {
    @Published private(set) var commands: [ScriptCommand] = []
    @Published private(set) var runningID: String?
    @Published private(set) var output: AutomationOutput?
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private var process: AutomationProcess?
    private var generation = UUID()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; reload() }
    func reload() {
        cancel()
        commands = (defaults.data(forKey: "scriptCommands").flatMap { try? JSONDecoder().decode([ScriptCommand].self, from: $0) } ?? []).filter { (try? $0.validate()) != nil }
    }
    func save(_ command: ScriptCommand) throws {
        try command.validate()
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            if runningID == command.id { cancel() }
            commands[index] = command
        } else { commands.append(command) }
        persist()
    }
    func importCommands(_ imported: [ScriptCommand]) throws {
        for command in imported { try command.validate() }
        for var command in imported { command.enabled = false; try save(command) }
    }
    func setEnabled(id: String, enabled: Bool) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        if !enabled, runningID == id { cancel() }
        commands[index].enabled = enabled; persist()
    }
    func remove(id: String) { if runningID == id { cancel() }; commands.removeAll { $0.id == id }; persist() }
    func run(id: String, arguments: [String] = [], completion: ((String?) -> Void)? = nil) {
        guard runningID == nil else { completion?("Another script is running."); return }
        guard let command = commands.first(where: { $0.id == id && $0.enabled }) else { completion?("Review and enable this script in Settings first."); return }
        let runner = AutomationProcess(), token = UUID(); generation = token; process = runner
        runningID = id; output = nil; error = nil
        Task {
            let result = await Task.detached { Result { try runner.execute(executable: command.executable, arguments: command.arguments + arguments, timeout: command.timeout) } }.value
            guard generation == token else { completion?(AutomationFailure.cancelled.localizedDescription); return }
            runningID = nil; process = nil
            switch result { case .success(let value): output = value; completion?(nil)
            case .failure(let failure): error = failure.localizedDescription; completion?(error) }
        }
    }
    func cancel() { if runningID != nil { error = AutomationFailure.cancelled.localizedDescription }; generation = UUID(); process?.cancel(); process = nil; runningID = nil }
    private func persist() { if let data = try? JSONEncoder().encode(commands) { defaults.set(data, forKey: "scriptCommands") } }
}
