import AppKit
import SwiftUI

struct SnippetSettingsView: View {
    @ObservedObject var store: SnippetStore
    @AppStorage(SnippetExpansionService.enabledDefaultsKey) private var expansionEnabled = false
    @State private var editingID: String?
    @State private var name = ""
    @State private var template = ""
    @State private var keyword = ""
    @State private var error: String?
    @State private var expansionMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Use {name} for prompted values, {name:friend} for a default, and {date}, {time}, or {clipboard} for local values. Select a snippet in the launcher to preview and copy."))
                Toggle(L("Expand snippet keywords while typing"), isOn: $expansionEnabled)
                    .onChange(of: expansionEnabled) { _, enabled in
                        SnippetExpansionService.shared.configure(store: store)
                        if !SnippetExpansionService.shared.setEnabled(enabled) {
                            expansionEnabled = false
                            expansionMessage = L("Allow Kebloop in System Settings → Privacy & Security → Accessibility, then enable keyword expansion again.")
                        } else {
                            expansionMessage = enabled
                                ? L("Type a keyword followed by a space to expand it. Snippets needing a value without a default stay untouched.")
                                : nil
                        }
                    }
                Text(L("Expansion is off by default. While enabled, Kebloop keeps a short typing buffer in memory, clears it when the app or text field changes, and skips secure input fields."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let expansionMessage { Text(expansionMessage).font(.caption).foregroundStyle(.secondary) }

                ForEach(store.snippets) { snippet in
                    HStack {
                        Button(snippet.name) { editingID = snippet.id; name = snippet.name; template = snippet.template; keyword = snippet.keyword ?? ""; error = nil }
                        if let keyword = snippet.keyword { Text(keyword).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        Spacer()
                        Button(L("Delete"), role: .destructive) { store.remove(id: snippet.id) }
                    }
                }
                TextField(L("Name"), text: $name)
                TextField(L("Expansion keyword (optional)"), text: $keyword)
                Text(L("The keyword expands after a space. Use a distinctive prefix such as ;addr to avoid accidental matches."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $template).frame(minHeight: 150).accessibilityLabel(L("Snippet text"))
                Text(template).lineLimit(5).textSelection(.enabled)
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button(L("Save")) {
                        do { try store.save(id: editingID, name: name, template: template, keyword: keyword); editingID = nil; name = ""; template = ""; keyword = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                    Button(L("New Snippet")) { editingID = nil; name = ""; template = ""; keyword = ""; error = nil }
                }
            }
            .padding(20)
            .onAppear {
                SnippetExpansionService.shared.configure(store: store)
                if expansionEnabled && !SnippetExpansionService.shared.setEnabled(true) {
                    expansionEnabled = false
                    expansionMessage = L("Allow Kebloop in System Settings → Privacy & Security → Accessibility, then enable keyword expansion again.")
                }
            }
        }
    }
}

@MainActor enum SnippetPresenter {
    static func prepare(_ snippet: Snippet, pasteboard: NSPasteboard = .general, runAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }, isTrusted: () -> Bool = { AXIsProcessTrusted() }) -> (text: String, insert: Bool)? {
        var values: [String: String] = [:]
        for name in snippet.placeholders {
            let alert = NSAlert(); alert.messageText = snippet.name; alert.informativeText = "\(L("Value for")) \(name)"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); field.setAccessibilityLabel(name)
            field.stringValue = snippet.placeholderDefaults[name] ?? ""
            alert.accessoryView = field; alert.addButton(withTitle: L("Continue")); alert.addButton(withTitle: L("Cancel"))
            alert.window.initialFirstResponder = field
            guard runAlert(alert) == .alertFirstButtonReturn else { return nil }; values[name] = field.stringValue
        }
        guard let text = try? snippet.render(values: values) else { return nil }
        let preview = NSAlert(); preview.messageText = snippet.name
        preview.informativeText = L("Review the text. Insert uses Accessibility to paste into the previous app. Copy needs no permission.")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 220)); scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds); view.string = text; view.isEditable = false; view.isSelectable = true
        scroll.documentView = view; preview.accessoryView = scroll
        preview.addButton(withTitle: L("Copy")); preview.addButton(withTitle: L("Insert")); preview.addButton(withTitle: L("Cancel"))
        let response = runAlert(preview)
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return nil }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        if response == .alertSecondButtonReturn, !isTrusted() {
            let alert = NSAlert(); alert.messageText = L("Text copied")
            alert.informativeText = L("Allow Kebloop in System Settings → Privacy & Security → Accessibility to insert text. You can paste the copied text now.")
            _ = runAlert(alert); return (text, false)
        }
        return (text, response == .alertSecondButtonReturn)
    }
    static func paste() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }
}
