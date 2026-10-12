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
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private let index = ApplicationIndex()
    private let hotkey = HotkeyService()
    private let quicklinks = QuicklinkStore()
    private let clipboard = ClipboardHistoryStore()
    private let aliases = AppAliasStore()
    private let ai = AIHandoffService()
    private var shortcuts: AppShortcutStore!
    private var emojiPicker: EmojiPickerController?
    private var launcher: LauncherPanelController!
    private var statusItem: NSStatusItem!
    private var settings: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcuts = AppShortcutStore(index: index, hotkey: hotkey)
        configureMenus()
        launcher = LauncherPanelController(index: index, quicklinks: quicklinks, clipboard: clipboard, aliases: aliases, ai: ai)
        launcher.onSettings = { [weak self] in self?.showSettings() }
        launcher.onEmoji = { [weak self] in self?.showEmoji() }
        launcher.onAI = { [weak self] query in self?.sendToAI(query) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "Kebloop")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Kebloop", action: #selector(openLauncher), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Refresh Applications", action: #selector(refresh), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kebloop", action: #selector(quit), keyEquivalent: "")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        hotkey.onPress = { [weak self] in self?.launcher.toggle() }
        preferences.applyShortcut = { [weak self] in self?.registerShortcut() }
        registerShortcut()
        index.refresh()
        if !UserDefaults.standard.bool(forKey: "automaticLoginConfigured") {
            preferences.setLogin(true)
            if preferences.loginEnabled { UserDefaults.standard.set(true, forKey: "automaticLoginConfigured") }
        }
        // A normal manual launch opens the panel. Login launches stay in the menu bar.
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == type(general: "logi")
        if !launchedAtLogin { launcher.show() }
    }
    private func configureMenus() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: "Hide Kebloop", action: #selector(hideInterface), keyEquivalent: "q")
        hideItem.target = self
        let quitItem = appMenu.addItem(withTitle: "Quit Kebloop", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                       ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            let item = editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
            item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : .command
        }
        editItem.submenu = editMenu
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }
    func windowWillClose(_ notification: Notification) { shortcuts?.resume() }
    private func type(general: String) -> UInt32 { general.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private func registerShortcut() {
        shortcuts?.suspend()
        preferences.shortcutError = hotkey.register(preferences.shortcut) ? nil : "This shortcut is unavailable. Choose another shortcut."
        shortcuts?.resume()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.show()
        return false
    }
    private func sendToAI(_ query: String) {
        launcher.dismiss(restoreFocus: false)
        ai.handoff(query) { [weak self] error in
            if let error { self?.launcher.showHandoffError(query: query, error: error) }
        }
    }
    private func showEmoji() {
        launcher.dismiss(restoreFocus: false)
        if emojiPicker == nil {
            emojiPicker = EmojiPickerController(onCopy: { [weak self] in self?.launcher.restorePreviousFocus() })
        }
        emojiPicker?.show()
    }
    @objc private func openLauncher() { launcher.show() }
    @objc private func refresh() { index.refresh() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc private func hideInterface() {
        emojiPicker?.dismiss()
        settings?.orderOut(nil)
        launcher.dismiss()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc func showSettings() {
        launcher.dismiss(restoreFocus: false)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Kebloop Settings"
            window.minSize = NSSize(width: 600, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, index: index, quicklinks: quicklinks, shortcuts: shortcuts, aliases: aliases, clipboard: clipboard, ai: ai))
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}
