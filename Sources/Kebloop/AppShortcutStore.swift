import AppKit
import Carbon
import Combine

struct AppShortcutBinding: Codable, Identifiable {
    let id: String
    let appPath: String
    let appName: String
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
}

@MainActor
final class AppShortcutStore: ObservableObject {
    @Published private(set) var bindings: [AppShortcutBinding]
    @Published private(set) var errors: [String: String] = [:]
    @Published var recorderConflict: String?
    private let index: ApplicationIndex
    private let hotkey: HotkeyService
    private var suspended = false
    init(index: ApplicationIndex, hotkey: HotkeyService) {
        self.index = index
        self.hotkey = hotkey
        bindings = UserDefaults.standard.data(forKey: "appShortcuts").flatMap { try? JSONDecoder().decode([AppShortcutBinding].self, from: $0) } ?? []
        resume()
    }
    func suspend() {
        suspended = true
        hotkey.isSuspended = true
        hotkey.suspendLauncher()
        for binding in bindings { hotkey.unregisterBinding(id: binding.id) }
    }
    func resume() {
        suspended = false
        hotkey.isSuspended = false
        hotkey.resumeLauncher()
        errors = [:]
        var registered = Set<String>()
        for binding in bindings {
            let combination = "\(binding.keyCode):\(binding.modifiers)"
            if !registered.insert(combination).inserted { errors[binding.id] = "This shortcut is already assigned to another app."; continue }
            register(binding)
        }
    }
    @discardableResult
    func assign(app: IndexedApplication, keyCode: UInt32, modifiers: UInt32, label: String) -> Bool {
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            recorderConflict = "Include Command, Option, or Control."; return false
        }
        if hotkey.conflictsWithLauncher(keyCode: keyCode, modifiers: modifiers) {
            recorderConflict = "This shortcut opens Kebloop. Choose a different shortcut."; return false
        }
        if let duplicate = bindings.first(where: { $0.appPath != app.path && $0.keyCode == keyCode && $0.modifiers == modifiers }) {
            recorderConflict = "Already assigned to \(duplicate.appName)."; return false
        }
        let binding = AppShortcutBinding(id: app.path, appPath: app.path, appName: app.name, keyCode: keyCode, modifiers: modifiers, label: label)
        if let offset = bindings.firstIndex(where: { $0.appPath == app.path }) { bindings[offset] = binding }
        else { bindings.append(binding) }
        recorderConflict = nil
        persist()
        if !suspended { register(binding) }
        return true
    }
    func remove(id: String) {
        hotkey.unregisterBinding(id: id)
        bindings.removeAll { $0.id == id }
        errors.removeValue(forKey: id)
        persist()
    }
    private func register(_ binding: AppShortcutBinding) {
        let success = hotkey.registerBinding(id: binding.id, keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak self] in
            guard let self else { return }
            self.index.launch(IndexedApplication(name: binding.appName, path: binding.appPath)) { [weak self] error in
                if let error { self?.errors[binding.id] = error.localizedDescription }
            }
        }
        errors[binding.id] = success ? nil : "Shortcut unavailable. It may be used by macOS or another app."
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(data, forKey: "appShortcuts") }
    }
}
