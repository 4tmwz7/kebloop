import AppKit
import ApplicationServices
import Carbon
import SwiftUI

struct WindowManagementSettingsView: View {
    @ObservedObject var store: CommandShortcutStore
    @State private var recording: LauncherCommand?
    @State private var trusted = AXIsProcessTrusted()
    @State private var presetFeedback: String?
    @AccessibilityFocusState private var shortcutFocus: String?

    private let groups: [(String, [LauncherCommand])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter]),
        ("Thirds", [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds]),
        ("Size & Position", [.maximizeWindow, .centerWindow, .restoreWindow]),
        ("Displays", [.previousDisplay, .nextDisplay])
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Accessibility access"), value: trusted ? L("Enabled") : L("Required"))
                Text(L("Arrange the focused window of your active app with a global shortcut or a launcher command. Windows fit within the display’s usable area, leaving room for the Dock and menu bar."))
                    .foregroundStyle(.secondary)
                if !trusted {
                    Button(L("Open Accessibility Settings")) {
                        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button(L("Use Suggested Shortcuts"), action: applyPreset)
                    .disabled(recording != nil)
                Text(L("Uses Control–Option with arrow keys for halves, U/I/J/K for quarters, D/F/G for thirds, E/T for two thirds, Return to maximize, C to center, and Delete to restore. Add Shift to Left/Right for displays. Existing shortcuts are kept; conflicts are skipped."))
                    .font(.caption).foregroundStyle(.secondary)
                if let presetFeedback { Text(presetFeedback).font(.callout).accessibilityAddTraits(.updatesFrequently) }
            }
            ForEach(groups, id: \.0) { title, commands in
                Section(L(title)) {
                    ForEach(commands) { command in
                        shortcutRow(command)
                    }
                }
            }
            Section {
                Text(L("Restore returns to the frame saved before the first arrangement. Full-screen, minimized, sheet, and fixed-size windows cannot be arranged. Display actions require more than one display."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = AXIsProcessTrusted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trusted = AXIsProcessTrusted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stopRecording() }
        .onDisappear(perform: stopRecording)
    }

    private func shortcutRow(_ command: LauncherCommand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(command.title, systemImage: command.symbol)
                Spacer()
                Button(store.bindings.first { $0.id == command.id }?.label ?? L("Record Shortcut")) {
                    stopRecording()
                    recording = command
                    store.recorderConflict = nil
                    store.suspend()
                }
                .accessibilityLabel("\(command.title): \(store.bindings.first { $0.id == command.id }?.label ?? L("Record Shortcut"))")
                .accessibilityFocused($shortcutFocus, equals: command.id)
                if store.bindings.contains(where: { $0.id == command.id }) {
                    Button(role: .destructive) { store.remove(id: command.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove shortcut for \(command.title)")
                }
            }
            if let error = store.errors[command.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if recording == command {
                Text(L("Press Command, Option, or Control with a key. Press Escape to cancel."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Cancel"), action: stopRecording)
                ShortcutRecorder { keyCode, modifiers, label in
                    if store.assign(commandID: command.id, keyCode: keyCode, modifiers: modifiers, label: label) {
                        stopRecording()
                        shortcutFocus = command.id
                    }
                } cancel: { stopRecording() }
                .frame(width: 1, height: 1)
                if let conflict = store.recorderConflict {
                    Text(conflict).font(.caption).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
    }

    private func stopRecording() {
        guard recording != nil else { return }
        recording = nil
        store.recorderConflict = nil
        store.resume()
    }

    private func applyPreset() {
        var added = 0
        var conflicts: [String] = []
        store.suspend()
        for binding in WindowShortcutPreset.bindings where !store.bindings.contains(where: { $0.id == binding.id }) {
            if store.assign(commandID: binding.id, keyCode: binding.keyCode, modifiers: binding.modifiers, label: binding.label) {
                added += 1
            } else { conflicts.append(LauncherCommand(rawValue: binding.id)?.title ?? binding.id) }
        }
        store.recorderConflict = nil
        store.resume()
        let summary = String(format: L("Added %d shortcuts."), added)
        presetFeedback = conflicts.isEmpty ? summary : summary + " " + L("Conflicts skipped:") + " " + conflicts.joined(separator: ", ")
    }
}

enum WindowShortcutPreset {
    static let bindings: [CommandShortcutBinding] = {
        let keys: [(LauncherCommand, Int, String)] = [
            (.leftHalf, kVK_LeftArrow, "←"), (.rightHalf, kVK_RightArrow, "→"),
            (.topHalf, kVK_UpArrow, "↑"), (.bottomHalf, kVK_DownArrow, "↓"),
            (.topLeftQuarter, kVK_ANSI_U, "U"), (.topRightQuarter, kVK_ANSI_I, "I"),
            (.bottomLeftQuarter, kVK_ANSI_J, "J"), (.bottomRightQuarter, kVK_ANSI_K, "K"),
            (.leftThird, kVK_ANSI_D, "D"), (.centerThird, kVK_ANSI_F, "F"), (.rightThird, kVK_ANSI_G, "G"),
            (.leftTwoThirds, kVK_ANSI_E, "E"), (.rightTwoThirds, kVK_ANSI_T, "T"),
            (.maximizeWindow, kVK_Return, "↩"), (.centerWindow, kVK_ANSI_C, "C"), (.restoreWindow, kVK_Delete, "⌫"),
            (.previousDisplay, kVK_LeftArrow, "←"), (.nextDisplay, kVK_RightArrow, "→")
        ]
        return keys.map { command, key, label in
            let display = command == .previousDisplay || command == .nextDisplay
            return CommandShortcutBinding(id: command.id, keyCode: UInt32(key),
                                          modifiers: UInt32(controlKey | optionKey) | (display ? UInt32(shiftKey) : 0),
                                          label: (display ? "⌃⌥⇧ " : "⌃⌥ ") + label)
        }
    }()
}
