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
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { service.onPress?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) -> Bool {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
        let id = EventHotKeyID(signature: 0x4B45424C, id: 1)
        return RegisterEventHotKey(UInt32(kVK_Space), shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotkey) == noErr
    }
    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
