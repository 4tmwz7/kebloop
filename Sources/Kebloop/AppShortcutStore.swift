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
    var isEnabled: (AppShortcutBinding) -> Bool = { _ in true }
    private let index: ApplicationIndex
    private let hotkey: HotkeyService
    private let defaults: UserDefaults
    init(index: ApplicationIndex, hotkey: HotkeyService, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.index = index
        self.hotkey = hotkey
        bindings = defaults.data(forKey: "appShortcuts").flatMap { try? JSONDecoder().decode([AppShortcutBinding].self, from: $0) } ?? []
        resume()
    }
    func suspend() {
        hotkey.beginRecording()
    }
    func resume() {
        unregisterAll()
        errors = [:]
        var registered = Set<String>()
        for binding in bindings where isEnabled(binding) {
            let combination = "\(binding.keyCode):\(binding.modifiers)"
            if !registered.insert(combination).inserted { errors[binding.id] = "This shortcut is already assigned to another app."; continue }
            register(binding)
        }
        hotkey.endRecording()
        for binding in bindings where hotkey.registrationErrors.contains(binding.id) { errors[binding.id] = "Shortcut unavailable. It may be used by macOS or another app." }
    }
    func unregisterAll() { for binding in bindings { hotkey.unregisterBinding(id: binding.id) } }
    func reload(register: Bool = true) {
        unregisterAll()
        bindings = defaults.data(forKey: "appShortcuts").flatMap { try? JSONDecoder().decode([AppShortcutBinding].self, from: $0) } ?? []
        if register { resume() }
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
        guard !hotkey.conflictsWithBinding(id: app.path, keyCode: keyCode, modifiers: modifiers) else { recorderConflict = "Already assigned to an app or command."; return false }
        let binding = AppShortcutBinding(id: app.path, appPath: app.path, appName: app.name, keyCode: keyCode, modifiers: modifiers, label: label)
        guard register(binding) else { recorderConflict = "Shortcut unavailable. It may be used by macOS or another app."; return false }
        if let offset = bindings.firstIndex(where: { $0.appPath == app.path }) { bindings[offset] = binding }
        else { bindings.append(binding) }
        recorderConflict = nil
        persist()
        return true
    }
    func remove(id: String) {
        hotkey.unregisterBinding(id: id)
        bindings.removeAll { $0.id == id }
        errors.removeValue(forKey: id)
        persist()
    }
    @discardableResult
    private func register(_ binding: AppShortcutBinding) -> Bool {
        guard isEnabled(binding) else { hotkey.unregisterBinding(id: binding.id); errors[binding.id] = nil; return true }
        let success = hotkey.registerBinding(id: binding.id, keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak self] in
            guard let self else { return }
            ApplicationControlService.perform(.toggleFocus, for: IndexedApplication(name: binding.appName, path: binding.appPath)) { [weak self] error in
                self?.errors[binding.id] = error?.localizedDescription
            }
        }
        errors[binding.id] = success ? nil : "Shortcut unavailable. It may be used by macOS or another app."
        return success
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: "appShortcuts") }
    }
}
