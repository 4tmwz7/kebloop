import AppKit
import Carbon

/// Keeps only a short in-memory tail of typed characters and resolves an exact,
/// space-terminated snippet keyword. This small value type is also testable
/// without installing a system event tap.
struct SnippetKeywordMatcher {
    private(set) var buffer = ""
    let maximumBufferLength: Int

    init(maximumBufferLength: Int = 128) {
        self.maximumBufferLength = max(1, maximumBufferLength)
    }

    mutating func reset() { buffer = "" }

    mutating func record(_ character: String, snippets: [Snippet]) -> Snippet? {
        guard character.count == 1 else { reset(); return nil }

        if character == " " {
            let candidates = snippets.compactMap { snippet -> (Snippet, String)? in
                guard let keyword = snippet.keyword, !keyword.isEmpty else { return nil }
                return (snippet, keyword)
            }.sorted { $0.1.count > $1.1.count }

            for (snippet, keyword) in candidates where buffer.count >= keyword.count {
                let trigger = String(buffer.suffix(keyword.count))
                guard trigger.compare(keyword, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame else { continue }
                let prefix = buffer.dropLast(keyword.count)
                if let previous = prefix.last, previous.isLetter || previous.isNumber || previous == "_" { continue }
                reset()
                return snippet.canExpandAutomatically ? snippet : nil
            }
        }

        buffer.append(character)
        if buffer.count > maximumBufferLength { buffer = String(buffer.suffix(maximumBufferLength)) }
        return nil
    }
}

enum SnippetExpansionPlan {
    /// The terminal space has already been suppressed by the event tap, so
    /// replacement must erase only the keyword that reached the target app.
    static func eraseCount(for keyword: String) -> Int { keyword.count }
}

/// An explicitly enabled macOS keyboard event tap for local snippet expansion.
/// No text is persisted; the matcher retains at most 128 characters and resets
/// whenever focus, application, or keyboard navigation changes.
@MainActor
final class SnippetExpansionService {
    static let shared = SnippetExpansionService()
    static let enabledDefaultsKey = "snippetKeywordExpansionEnabled"
    private static let generatedEventTag: Int64 = 0x4B45424C
    private static let maximumAutomaticExpansionLength = 4096

    private weak var store: SnippetStore?
    private var matcher = SnippetKeywordMatcher()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var observedApplicationPID: pid_t?
    private var observedFocusHash: CFHashCode?

    private init() {}

    func configure(store: SnippetStore) {
        self.store = store
        resetBuffer()
        if UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) {
            _ = start()
        }
    }

    func resetForSnippetChanges() { resetBuffer() }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            stop()
            return true
        }
        guard start() else { return false }
        UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
        return true
    }

    @discardableResult
    private func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard tap == nil else { return true }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) else {
            return false
        }

        tap = createdTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.observedApplicationPID = app?.processIdentifier
                self?.resetBuffer()
            }
        }
        resetBuffer()
        return true
    }

    private func stop() {
        resetBuffer()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
    }

    private func resetBuffer() {
        matcher.reset()
        observedFocusHash = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<SnippetExpansionService>.fromOpaque(userInfo).takeUnretainedValue()
        return MainActor.assumeIsolated {
            service.handle(event, type: type)
        }
    }

    private func handle(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.generatedEventTag {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let focus = focusedTextInput(), !focus.isSecure else {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        if observedApplicationPID != app.processIdentifier || observedFocusHash != focus.hash {
            observedApplicationPID = app.processIdentifier
            observedFocusHash = focus.hash
            matcher.reset()
        }
        if focus.hasSelection {
            matcher.reset()
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            matcher.reset()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if Self.navigationKeyCodes.contains(UInt16(keyCode)) || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            matcher.reset()
            return Unmanaged.passUnretained(event)
        }

        var characters = [UniChar](repeating: 0, count: 8)
        var characterCount = 0
        characters.withUnsafeMutableBufferPointer { buffer in
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &characterCount, unicodeString: buffer.baseAddress)
        }
        guard characterCount <= characters.count else {
            matcher.reset()
            return Unmanaged.passUnretained(event)
        }
        let input = String(utf16CodeUnits: characters, count: Int(characterCount))
        guard !input.isEmpty, let store else {
            matcher.reset()
            return Unmanaged.passUnretained(event)
        }
        guard let snippet = matcher.record(input, snippets: store.snippets) else {
            return Unmanaged.passUnretained(event)
        }

        // The final space is suppressed only when every user placeholder has a
        // default, so no trigger text is removed for snippets needing a prompt.
        guard snippet.canExpandAutomatically,
              !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              focusedTextInput()?.hash == focus.hash,
              let text = try? snippet.render(values: [:]),
              let events = expansionEvents(keyword: snippet.keyword ?? "", replacement: text) else {
            matcher.reset()
            return Unmanaged.passUnretained(event)
        }

        for generatedEvent in events { generatedEvent.post(tap: .cghidEventTap) }
        matcher.reset()
        return nil
    }

    private struct FocusedTextInput {
        let hash: CFHashCode
        let hasSelection: Bool
        let isSecure: Bool
    }

    private func focusedTextInput() -> FocusedTextInput? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, 0.05)
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String,
              [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) else {
            return nil
        }
        var subroleValue: CFTypeRef?
        let isSecure = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subroleValue) == .success
            && (subroleValue as? String) == (kAXSecureTextFieldSubrole as String)

        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &selectionValue) == .success,
              let selectionValue, CFGetTypeID(selectionValue) == AXValueGetTypeID() else { return nil }
        let selection = unsafeBitCast(selectionValue, to: AXValue.self)
        guard AXValueGetType(selection) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selection, .cfRange, &range) else { return nil }
        let hasSelection = range.length > 0
        return FocusedTextInput(hash: CFHash(focused), hasSelection: hasSelection, isSecure: isSecure)
    }

    private static let navigationKeyCodes: Set<UInt16> = [
        36, 48, 51, 53, // Return, Tab, Delete, Escape
        115, 116, 117, 119, // Home, Page Up, Forward Delete, End
        121, 123, 124, 125, 126 // Page Down, Left, Right, Down, Up
    ]

    private func expansionEvents(keyword: String, replacement: String) -> [CGEvent]? {
        guard replacement.utf16.count <= Self.maximumAutomaticExpansionLength else { return nil }
        let eraseCount = SnippetExpansionPlan.eraseCount(for: keyword)
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        var events: [CGEvent] = []
        for _ in 0..<eraseCount {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else { return nil }
            tag(down); tag(up)
            events.append(contentsOf: [down, up])
        }
        if !replacement.isEmpty {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
            let characters = Array(replacement.utf16)
            down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            tag(down); tag(up)
            events.append(contentsOf: [down, up])
        }
        return events
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.generatedEventTag)
    }
}
