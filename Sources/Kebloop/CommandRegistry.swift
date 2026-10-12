import Foundation
import Carbon
import Combine

// Raw values are persisted identifiers; keep them stable across releases.
enum LauncherCommand: String, CaseIterable, Identifiable {
    case clipboard, quicklinks, emoji, settings, shutdown, browse, help, onboarding, profiles, webSearch, appleShortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: String(localized: "Clipboard History")
        case .quicklinks: String(localized: "Quicklinks")
        case .emoji: String(localized: "Emoji & Symbols")
        case .settings: String(localized: "Open Settings")
        case .shutdown: String(localized: "Shut Down…")
        case .browse: String(localized: "Browse Commands")
        case .help: String(localized: "Help")
        case .onboarding: String(localized: "Welcome to Kebloop")
        case .profiles: String(localized: "Profiles")
        case .webSearch: String(localized: "Web Search")
        case .appleShortcuts: String(localized: "Apple Shortcuts")
        }
    }
    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .quicklinks: "link"
        case .emoji: "face.smiling"
        case .settings: "gearshape"
        case .shutdown: "power"
        case .browse: "square.grid.2x2"
        case .help: "questionmark.circle"
        case .onboarding: "sparkles"
        case .profiles: "person.crop.circle"
        case .webSearch: "globe"
        case .appleShortcuts: "square.stack.3d.up"
        }
    }
    var aliases: [String] {
        switch self {
        case .clipboard: ["clipboard", "history", "paste"]
        case .quicklinks: ["quicklinks", "links", "bookmarks"]
        case .emoji: ["emoji", "symbols", "emoji & symbols"]
        case .settings: ["settings", "preferences", "open settings"]
        case .shutdown: ["shutdown", "shut down", "power off", "turn off"]
        case .browse: ["browse", "commands", "all commands"]
        case .help: ["help", "guide"]
        case .onboarding: ["welcome", "onboarding", "tutorial"]
        case .profiles: ["profiles", "switch profile"]
        case .webSearch: ["web search", "search web"]
        case .appleShortcuts: ["apple shortcuts", "shortcuts", "automation"]
        }
    }
}

struct CommandShortcutBinding: Codable, Identifiable {
    let id: String
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
}

@MainActor
final class CommandShortcutStore: ObservableObject {
    @Published private(set) var bindings: [CommandShortcutBinding] = []
    @Published private(set) var errors: [String: String] = [:]
    @Published var recorderConflict: String?
    var isEnabled: (String) -> Bool = { _ in true }
    var onCommand: ((String) -> Void)?
    private let hotkey: HotkeyService
    private let defaults: UserDefaults
    init(hotkey: HotkeyService, defaults: UserDefaults = .standard) {
        self.hotkey = hotkey
        self.defaults = defaults
        reload()
    }
    func unregisterAll() { for binding in bindings { hotkey.unregisterBinding(id: "command:\(binding.id)") } }
    func reload(register: Bool = true) {
        unregisterAll()
        bindings = defaults.data(forKey: "commandShortcuts").flatMap { try? JSONDecoder().decode([CommandShortcutBinding].self, from: $0) } ?? []
        if register { resume() }
    }
    func suspend() { hotkey.beginRecording() }
    func resume() {
        unregisterAll()
        errors = [:]
        for binding in bindings where isEnabled(binding.id) { register(binding) }
        hotkey.endRecording()
        for binding in bindings where hotkey.registrationErrors.contains("command:\(binding.id)") { errors[binding.id] = "Shortcut unavailable. It may be used by macOS or another app." }
    }
    @discardableResult
    func assign(commandID: String, keyCode: UInt32, modifiers: UInt32, label: String) -> Bool {
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { recorderConflict = "Include Command, Option, or Control."; return false }
        guard !hotkey.conflictsWithLauncher(keyCode: keyCode, modifiers: modifiers) else { recorderConflict = "This shortcut opens Kebloop."; return false }
        guard !hotkey.conflictsWithBinding(id: "command:\(commandID)", keyCode: keyCode, modifiers: modifiers) else { recorderConflict = "This shortcut is already assigned to an app or command."; return false }
        let binding = CommandShortcutBinding(id: commandID, keyCode: keyCode, modifiers: modifiers, label: label)
        guard register(binding) else { recorderConflict = "Shortcut unavailable. It may be used by macOS or another app."; return false }
        if let offset = bindings.firstIndex(where: { $0.id == commandID }) { bindings[offset] = binding } else { bindings.append(binding) }
        persist()
        recorderConflict = nil
        return true
    }
    func remove(id: String) {
        hotkey.unregisterBinding(id: "command:\(id)")
        bindings.removeAll { $0.id == id }
        errors[id] = nil
        persist()
    }
    @discardableResult
    private func register(_ binding: CommandShortcutBinding) -> Bool {
        guard isEnabled(binding.id) else { hotkey.unregisterBinding(id: "command:\(binding.id)"); errors[binding.id] = nil; return true }
        let success = hotkey.registerBinding(id: "command:\(binding.id)", keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak self] in self?.onCommand?(binding.id) }
        errors[binding.id] = success ? nil : "Shortcut unavailable or already assigned."
        return success
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: "commandShortcuts") }
    }
}
