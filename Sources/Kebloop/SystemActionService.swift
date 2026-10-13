import AppKit
import CoreServices
import ApplicationServices

enum SystemActionService {
    enum Action: CaseIterable { case lock, sleep, restart, logOut, toggleMute, toggleAppearance }
    enum Failure: LocalizedError {
        case script(String)
        var errorDescription: String? { if case .script(let message) = self { return message }; return nil }
    }
    static func perform(_ action: Action) async throws {
        switch action {
        case .restart, .logOut:
            // loginwindow presents its native confirmation and unsaved-document handling.
            try await Task.detached(priority: .userInitiated) {
                _ = try makeConfirmationEvent(action).sendEvent(options: [.noReply, .canInteract], timeout: 5)
            }.value
        case .sleep:
            try await script("tell application \"System Events\" to sleep")
        case .lock:
            guard AXIsProcessTrusted() else { throw Failure.script("Enable Kebloop in System Settings → Privacy & Security → Accessibility to lock the screen.") }
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else {
                throw Failure.script("Could not create the Lock Screen shortcut.")
            }
            down.flags = [.maskControl, .maskCommand]; up.flags = [.maskControl, .maskCommand]
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        case .toggleMute:
            try await script("set volume output muted not (output muted of (get volume settings))")
        case .toggleAppearance:
            try await script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        }
    }
    static func makeConfirmationEvent(_ action: Action) -> NSAppleEventDescriptor {
        precondition(action == .restart || action == .logOut)
        return NSAppleEventDescriptor(eventClass: kCoreEventClass,
            eventID: action == .restart ? kAEShowRestartDialog : kAELogOut,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
    private static func script(_ source: String) async throws {
        let process = AutomationProcess()
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try process.execute(executable: "/usr/bin/osascript", arguments: ["-e", source], timeout: 30)
            }.value
        } catch AutomationFailure.failed {
            throw Failure.script("The system action failed. Allow Kebloop to control System Events in System Settings → Privacy & Security → Automation, then try again.")
        }
    }
}
