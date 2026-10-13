import AppKit
import Carbon

/// Copies are retained when permissions, focus, or the clipboard change before insertion.
@MainActor
final class PasteService {
    enum Failure: LocalizedError, Equatable {
        case permission, secureInput, noTarget, focusChanged, clipboardChanged, eventCreation
        var errorDescription: String? {
            switch self {
            case .permission: return L("Copied. Allow Kebloop in System Settings → Privacy & Security → Accessibility to paste directly.")
            case .secureInput: return L("Copied. Direct paste is unavailable while secure input is active.")
            case .noTarget: return L("Copied. The previous application is no longer available.")
            case .focusChanged: return L("Copied. Paste cancelled because the active application changed.")
            case .clipboardChanged: return L("Paste cancelled because the clipboard changed.")
            case .eventCreation: return L("Copied. Could not create the paste keyboard event.")
            }
        }
    }

    private var task: Task<Void, Never>?
    private let trusted: () -> Bool
    private let secureInput: () -> Bool
    private let frontmostPID: () -> pid_t?
    private let clipboardRevision: () -> Int
    private let postPaste: () -> Bool

    init(trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         clipboardRevision: @escaping () -> Int = { NSPasteboard.general.changeCount },
         postPaste: @escaping () -> Bool = { PasteService.postKeyboardPaste() }) {
        self.trusted = trusted; self.secureInput = secureInput
        self.frontmostPID = frontmostPID; self.clipboardRevision = clipboardRevision; self.postPaste = postPaste
    }

    func cancel() { task?.cancel(); task = nil }

    func paste(into application: NSRunningApplication?, completion: @escaping (Failure?) -> Void) {
        cancel()
        guard let application, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(.noTarget); return
        }
        paste(targetPID: application.processIdentifier, activate: { application.activate(options: []) }, completion: completion)
    }

    // Separate focus/clipboard gates make it possible to test without sending keys to other apps.
    func paste(targetPID: pid_t, activate: () -> Bool, completion: @escaping (Failure?) -> Void) {
        cancel()
        guard trusted() else { completion(.permission); return }
        guard !secureInput() else { completion(.secureInput); return }
        let revision = clipboardRevision()
        guard activate() else { completion(.noTarget); return }
        task = Task { @MainActor [weak self] in
            // Give activation and the physical Return/modifier key-up time to settle.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            for _ in 0..<15 {
                guard !Task.isCancelled else { return }
                guard self.trusted() else { completion(.permission); return }
                guard !self.secureInput() else { completion(.secureInput); return }
                guard self.clipboardRevision() == revision else { completion(.clipboardChanged); return }
                let foreground = self.frontmostPID()
                if foreground == targetPID {
                    completion(self.postPaste() ? nil : .eventCreation)
                    return
                }
                if let foreground, foreground != ProcessInfo.processInfo.processIdentifier {
                    completion(.focusChanged); return
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            completion(.focusChanged)
        }
    }

    nonisolated private static func postKeyboardPaste() -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: 0x4B45424C)
        up.setIntegerValueField(.eventSourceUserData, value: 0x4B45424C)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
}
