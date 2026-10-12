import AppKit
import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var index: ApplicationIndex
    @ObservedObject var quicklinks: QuicklinkStore
    @ObservedObject var shortcuts: AppShortcutStore
    @ObservedObject var aliases: AppAliasStore
    @ObservedObject var clipboard: ClipboardHistoryStore
    @State private var editingID: String?
    @State private var linkName = ""
    @State private var linkTarget = ""
    @State private var linkError: String?
    @State private var appQuery = ""
    @State private var recordingApp: IndexedApplication?
    @State private var clearConfirmation = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            links.tabItem { Label("Quicklinks", systemImage: "link") }
            appShortcuts.tabItem { Label("App Shortcuts", systemImage: "command") }
            appAliases.tabItem { Label("Aliases", systemImage: "text.magnifyingglass") }
            clipboardSettings.tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
        }
        .padding(12)
        .frame(minWidth: 600, minHeight: 430)
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if recordingApp != nil { stopRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if recordingApp != nil { stopRecording() }
        }
    }

    private var general: some View {
        Form {
            Picker("Open launcher", selection: $preferences.shortcutID) {
                ForEach(Shortcut.choices) { Text($0.label).tag($0.id) }
            }.onChange(of: preferences.shortcutID) { _, _ in
                preferences.saveShortcut()
            }
            if let error = preferences.shortcutError { Text(error).foregroundStyle(.red).font(.caption) }
            Text("⌘ Space may conflict with Spotlight or Raycast.").font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: Binding(get: { preferences.loginEnabled }, set: { preferences.setLogin($0) }))
            if let error = preferences.loginError { Text(error).foregroundStyle(.red).font(.caption) }
            Button("Refresh Applications") { index.refresh() }.disabled(index.isRefreshing)
        }.formStyle(.grouped)
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open websites, files, and folders by name from the launcher.").foregroundStyle(.secondary)
            List(quicklinks.links) { link in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.name)
                        Text(link.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Edit") { editingID = link.id; linkName = link.name; linkTarget = link.target; linkError = nil }
                    Button { quicklinks.remove(id: link.id); if editingID == link.id { resetLink() } } label: { Image(systemName: "trash") }.help("Remove quicklink")
                }
            }
            HStack {
                TextField("Name", text: $linkName).frame(width: 160)
                TextField("https://example.com or ~/Documents", text: $linkTarget)
            }.textFieldStyle(.roundedBorder)
            if let error = linkError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(editingID == nil ? "Add Quicklink" : "Save Quicklink") {
                    linkError = quicklinks.save(id: editingID, name: linkName, target: linkTarget)
                    if linkError == nil { resetLink() }
                }.disabled(linkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || linkTarget.isEmpty)
                if editingID != nil { Button("Cancel") { resetLink() } }
            }
        }.padding(12)
    }

    private var appShortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search applications", text: $appQuery).textFieldStyle(.roundedBorder)
            Text("Open an app from anywhere with Command, Option, or Control plus a key.").font(.caption).foregroundStyle(.secondary)
            List(index.applications.filter { appQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(appQuery) }) { app in
                let binding = shortcuts.bindings.first { $0.appPath == app.path }
                HStack(spacing: 10) {
                    Group {
                        if let icon = index.icon(for: app) { Image(nsImage: icon).resizable() }
                        else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
                    }.frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        if let error = shortcuts.errors[app.path] { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                    Spacer()
                    Button(binding?.label ?? "Record Shortcut") {
                        recordingApp = app
                        shortcuts.recorderConflict = nil
                        shortcuts.suspend()
                    }
                    if let binding { Button { shortcuts.remove(id: binding.id) } label: { Image(systemName: "xmark.circle") }.help("Remove shortcut") }
                }
            }
            if let app = recordingApp {
                HStack {
                    Text("Press a shortcut for \(app.name)…").font(.callout)
                    ShortcutRecorder { keyCode, modifiers, label in
                        if shortcuts.assign(app: app, keyCode: keyCode, modifiers: modifiers, label: label) { stopRecording() }
                    } cancel: { stopRecording() }.frame(width: 1, height: 1)
                    Spacer()
                    Button("Cancel") { stopRecording() }
                }
                if let conflict = shortcuts.recorderConflict { Text(conflict).foregroundStyle(.red).font(.caption) }
            }
        }.padding(12).onDisappear { stopRecording() }
    }

    private var clipboardSettings: some View {
        Form {
            Toggle("Enable clipboard history", isOn: $clipboard.enabled)
            Text("Copied text is stored locally on this Mac. Disable history to stop collecting new items.").font(.callout).foregroundStyle(.secondary)
            Text("\(clipboard.items.count) saved items").foregroundStyle(.secondary)
            Button("Clear Clipboard History", role: .destructive) { clearConfirmation = true }
                .disabled(clipboard.items.isEmpty)
                .alert("Clear clipboard history?", isPresented: $clearConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear History", role: .destructive) { clipboard.clear() }
                } message: { Text("All saved clipboard items will be removed.") }
        }.formStyle(.grouped)
    }

    private var appAliases: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search applications", text: $appQuery).textFieldStyle(.roundedBorder)
            Text("Give an app a name to search for, such as “terminal” for Ghostty.")
                .font(.caption).foregroundStyle(.secondary)
            List(index.applications.filter { app in
                appQuery.isEmpty
                    || app.name.localizedCaseInsensitiveContains(appQuery)
                    || (aliases.alias(for: app)?.localizedCaseInsensitiveContains(appQuery) ?? false)
            }) { app in
                AppAliasRow(app: app, index: index, aliases: aliases)
            }
        }.padding(12)
    }

    private func resetLink() { editingID = nil; linkName = ""; linkTarget = ""; linkError = nil }
    private func stopRecording() { recordingApp = nil; shortcuts.recorderConflict = nil; shortcuts.resume() }
}

private struct AppAliasRow: View {
    let app: IndexedApplication
    @ObservedObject var index: ApplicationIndex
    @ObservedObject var aliases: AppAliasStore
    @State private var draft: String
    @State private var error: String?

    init(app: IndexedApplication, index: ApplicationIndex, aliases: AppAliasStore) {
        self.app = app
        self.index = index
        self.aliases = aliases
        _draft = State(initialValue: aliases.alias(for: app) ?? "")
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = index.icon(for: app) { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
            }.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            TextField("Alias", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit(save)
                .onChange(of: aliases.alias(for: app) ?? "") { _, value in draft = value }
            Button("Save") { save() }
            if aliases.alias(for: app) != nil {
                Button { aliases.remove(for: app); draft = ""; error = nil } label: {
                    Image(systemName: "xmark.circle")
                }.help("Remove alias")
            }
        }
    }

    private func save() {
        error = aliases.save(alias: draft, for: app)
        if error == nil { draft = aliases.alias(for: app) ?? "" }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    var record: (UInt32, UInt32, String) -> Void
    var cancel: () -> Void
    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.record = record
        view.cancel = cancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: ShortcutCaptureView, context: Context) { view.record = record; view.cancel = cancel }
    static func dismantleNSView(_ view: ShortcutCaptureView, coordinator: ()) {
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        view.record = nil
        view.cancel = nil
    }
}

private final class ShortcutCaptureView: NSView {
    var record: ((UInt32, UInt32, String) -> Void)?
    var cancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { cancel?(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return }
        let special: [UInt16: String] = [UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓"]
        let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        record?(UInt32(event.keyCode), modifiers, label + " " + key)
    }
}
