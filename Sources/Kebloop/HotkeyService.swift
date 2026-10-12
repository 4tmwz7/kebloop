import AppKit
import Carbon

struct Shortcut: Identifiable {
    let id: String
    let label: String
    let modifiers: UInt32
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
    private var launcherShortcut: Shortcut?
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 2
    private var bindings: [String: (reference: EventHotKeyRef, eventID: UInt32)] = [:]
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
    func suspendLauncher() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
    }
    func resumeLauncher() {
        if let launcherShortcut { _ = register(launcherShortcut) }
    }
    func conflictsWithLauncher(keyCode: UInt32, modifiers: UInt32) -> Bool {
        keyCode == UInt32(kVK_Space) && launcherShortcut?.modifiers == modifiers
    }
    func register(_ shortcut: Shortcut) -> Bool {
        launcherShortcut = shortcut
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
        let id = EventHotKeyID(signature: 0x4B45424C, id: 1)
        return RegisterEventHotKey(UInt32(kVK_Space), shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotkey) == noErr
    }
    func registerBinding(id: String, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregisterBinding(id: id)
        guard !conflictsWithLauncher(keyCode: keyCode, modifiers: modifiers) else { return false }
        let eventID = nextID
        nextID &+= 1
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x4B45424C, id: eventID)
        let status = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        bindings[id] = (reference, eventID)
        actions[eventID] = action
        return true
    }
    func unregisterBinding(id: String) {
        guard let binding = bindings.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(binding.reference)
        actions.removeValue(forKey: binding.eventID)
    }
    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        for binding in bindings.values { UnregisterEventHotKey(binding.reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
