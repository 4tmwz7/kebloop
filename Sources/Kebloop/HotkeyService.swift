import AppKit
import Carbon

struct Shortcut: Codable, Identifiable {
    let id: String
    let label: String
    let modifiers: UInt32
    let keyCode: UInt32
    init(id: String, label: String, modifiers: UInt32, keyCode: UInt32 = UInt32(kVK_Space)) {
        self.id = id; self.label = label; self.modifiers = modifiers; self.keyCode = keyCode
    }
    static let choices = [
        Shortcut(id: "option", label: "⌥ Space", modifiers: UInt32(optionKey)),
        Shortcut(id: "control", label: "⌃ Space", modifiers: UInt32(controlKey)),
        Shortcut(id: "commandShift", label: "⌘ ⇧ Space", modifiers: UInt32(cmdKey | shiftKey)),
        Shortcut(id: "command", label: "⌘ Space", modifiers: UInt32(cmdKey))
    ]
}

final class HotkeyService {
    var onPress: (() -> Void)?
    var isSuspended = false
    private(set) var registrationErrors: Set<String> = []
    private var launcherShortcut: Shortcut?
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 2
    private var bindings: [String: (reference: EventHotKeyRef?, eventID: UInt32, keyCode: UInt32, modifiers: UInt32)] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            let parameterStatus = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard parameterStatus == noErr, id.signature == 0x4B45424C else { return OSStatus(eventNotHandledErr) }
            let eventID = id.id
            DispatchQueue.main.async {
                guard !service.isSuspended else { return }
                if eventID == 1 { service.onPress?() }
                else { service.actions[eventID]?() }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func beginRecording() {
        guard !isSuspended else { return }
        isSuspended = true
        suspendLauncher()
        for (id, binding) in bindings {
            if let reference = binding.reference { UnregisterEventHotKey(reference) }
            bindings[id]?.reference = nil
        }
    }
    func endRecording() {
        guard isSuspended else { return }
        isSuspended = false
        resumeLauncher()
        for (id, binding) in bindings {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x4B45424C, id: binding.eventID)
            if RegisterEventHotKey(binding.keyCode, binding.modifiers, identifier, GetApplicationEventTarget(), 0, &reference) == noErr { bindings[id]?.reference = reference; registrationErrors.remove(id) }
            else { registrationErrors.insert(id) }
        }
    }
    func conflictsWithBinding(id: String, keyCode: UInt32, modifiers: UInt32) -> Bool {
        bindings.contains { $0.key != id && $0.value.keyCode == keyCode && $0.value.modifiers == modifiers }
    }
    func suspendLauncher() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
    }
    func resumeLauncher() {
        if let launcherShortcut { _ = register(launcherShortcut) }
    }
    func conflictsWithLauncher(keyCode: UInt32, modifiers: UInt32) -> Bool {
        keyCode == launcherShortcut?.keyCode && launcherShortcut?.modifiers == modifiers
    }
    func register(_ shortcut: Shortcut) -> Bool {
        guard !conflictsWithBinding(id: "", keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) else { return false }
        let previous = launcherShortcut
        launcherShortcut = shortcut
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
        let id = EventHotKeyID(signature: 0x4B45424C, id: 1)
        let success = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotkey) == noErr
        if isSuspended { suspendLauncher() }
        if !success {
            launcherShortcut = previous
            if !isSuspended, let previous {
                _ = RegisterEventHotKey(previous.keyCode, previous.modifiers, id, GetApplicationEventTarget(), 0, &hotkey)
            }
        }
        return success
    }
    func registerBinding(id: String, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        guard !conflictsWithLauncher(keyCode: keyCode, modifiers: modifiers), !conflictsWithBinding(id: id, keyCode: keyCode, modifiers: modifiers) else { return false }
        let previous = bindings[id]
        let previousAction = previous.flatMap { actions[$0.eventID] }
        unregisterBinding(id: id)
        let eventID = nextID
        nextID &+= 1
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x4B45424C, id: eventID)
        let status = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            if let previous, let previousAction {
                var restored: EventHotKeyRef?
                let previousIdentifier = EventHotKeyID(signature: 0x4B45424C, id: previous.eventID)
                if !isSuspended { _ = RegisterEventHotKey(previous.keyCode, previous.modifiers, previousIdentifier, GetApplicationEventTarget(), 0, &restored) }
                bindings[id] = (restored, previous.eventID, previous.keyCode, previous.modifiers)
                actions[previous.eventID] = previousAction
            }
            registrationErrors.insert(id); return false
        }
        if isSuspended { if let reference { UnregisterEventHotKey(reference) }; reference = nil }
        registrationErrors.remove(id)
        bindings[id] = (reference, eventID, keyCode, modifiers)
        actions[eventID] = action
        return true
    }
    func unregisterBinding(id: String) {
        registrationErrors.remove(id)
        guard let binding = bindings.removeValue(forKey: id) else { return }
        if let reference = binding.reference { UnregisterEventHotKey(reference) }
        actions.removeValue(forKey: binding.eventID)
    }
    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        for binding in bindings.values { if let reference = binding.reference { UnregisterEventHotKey(reference) } }
        if let handler { RemoveEventHandler(handler) }
    }
}
