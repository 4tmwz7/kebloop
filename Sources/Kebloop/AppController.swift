import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class Preferences: ObservableObject {
    @Published var shortcutID = UserDefaults.standard.string(forKey: "shortcut") ?? "option"
    @Published var shortcutError: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    var shortcut: Shortcut { Shortcut.choices.first { $0.id == shortcutID } ?? Shortcut.choices[0] }
    var applyShortcut: (() -> Void)?
    func saveShortcut() {
        UserDefaults.standard.set(shortcutID, forKey: "shortcut")
        applyShortcut?()
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginError = SMAppService.mainApp.status == .requiresApproval ? "Allow Kebloop in System Settings → General → Login Items." : nil
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginError = error.localizedDescription
        }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let index = ApplicationIndex()
    private let hotkey = HotkeyService()
    private var launcher: LauncherPanelController!
    private var statusItem: NSStatusItem!
    private var settings: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launcher = LauncherPanelController(index: index)
        launcher.onSettings = { [weak self] in self?.showSettings() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "Kebloop")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Kebloop", action: #selector(openLauncher), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Refresh Applications", action: #selector(refresh), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kebloop", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        hotkey.onPress = { [weak self] in self?.launcher.toggle() }
        preferences.applyShortcut = { [weak self] in self?.registerShortcut() }
        registerShortcut()
        index.refresh()
        // A normal manual launch opens the panel. Login launches stay in the menu bar.
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == type(general: "logi")
        if !launchedAtLogin { launcher.show() }
    }
    private func type(general: String) -> UInt32 { general.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private func registerShortcut() {
        preferences.shortcutError = hotkey.register(preferences.shortcut) ? nil : "This shortcut is unavailable. Choose another shortcut."
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.show()
        return false
    }
    @objc private func openLauncher() { launcher.show() }
    @objc private func refresh() { index.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc func showSettings() {
        launcher.dismiss(restoreFocus: false)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Kebloop Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences))
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "command.square.fill").font(.system(size: 36)).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Kebloop").font(.title2.weight(.semibold))
                    Text("Apps and answers. One shortcut away.").foregroundStyle(.secondary)
                }
            }
            Picker("Open launcher", selection: $preferences.shortcutID) {
                ForEach(Shortcut.choices) { Text($0.label).tag($0.id) }
            }.onChange(of: preferences.shortcutID) { _, _ in preferences.saveShortcut() }
            Text("⌘ Space may conflict with Spotlight or Raycast. Change their shortcut before assigning it here.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = preferences.shortcutError { Text(error).foregroundStyle(.red).font(.caption) }
            Toggle("Launch at login", isOn: Binding(get: { preferences.loginEnabled }, set: { preferences.setLogin($0) }))
            if let error = preferences.loginError { Text(error).foregroundStyle(.red).font(.caption) }
            Divider()
            Text("Type an app name or try 15% of 200. Return opens an app or copies an answer. Escape closes the launcher.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(28).frame(width: 440)
    }
}
