import SwiftUI
import AppKit

struct ScriptCommandsSettingsView: View {
    @ObservedObject var store: ScriptCommandStore
    @State private var editingID: String?
    @State private var title = ""
    @State private var summary = ""
    @State private var executable = ""
    @State private var arguments = ""
    @State private var timeout = 10.0
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Scripts run with your user privileges. Review the executable and arguments before enabling. Arguments and metadata are portable; never enter secrets here.")).font(.caption).foregroundStyle(.secondary)
            ForEach(store.commands) { command in
                HStack {
                    Toggle(command.title, isOn: Binding(get: { command.enabled }, set: { store.setEnabled(id: command.id, enabled: $0) }))
                    Button(L("Edit")) { editingID = command.id; title = command.title; summary = command.description; executable = command.executable; arguments = command.arguments.joined(separator: "\n"); timeout = command.timeout }
                    Button(L("Remove")) { store.remove(id: command.id) }
                }
                Text(command.executable + " " + command.arguments.joined(separator: " ")).font(.caption).textSelection(.enabled)
            }
            Divider()
            TextField(L("Title"), text: $title)
            TextField(L("Description"), text: $summary)
            HStack { TextField(L("Absolute executable or runtime path"), text: $executable); Button(L("Choose…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = false; if panel.runModal() == .OK { executable = panel.url?.path ?? "" } } }
            Text(L("Arguments: one literal argument per line. For an interpreted script, make its absolute path the first argument.")).font(.caption)
            TextEditor(text: $arguments).frame(height: 75).accessibilityLabel(L("Script arguments, one per line"))
            HStack {
                Text(L("Timeout (seconds)")); TextField(L("Timeout"), value: $timeout, format: .number).frame(width: 70)
                Button(editingID == nil ? "Add disabled script" : "Save script") {
                    do {
                        try store.save(ScriptCommand(id: editingID ?? UUID().uuidString, title: title, description: summary, executable: executable, arguments: arguments.isEmpty ? [] : arguments.components(separatedBy: "\n"), timeout: timeout, enabled: false))
                        editingID = nil; title = ""; summary = ""; executable = ""; arguments = ""; error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            ScriptOutputView(store: store)
        }
    }
}
struct ScriptOutputView: View {
    @ObservedObject var store: ScriptCommandStore
    var body: some View {
        VStack(alignment: .leading) {
            if store.runningID != nil { HStack { ProgressView(); Text(L("Running script…")); Button(L("Cancel")) { store.cancel() } } }
            if let error = store.error { Text(error).foregroundStyle(.red) }
            if let output = store.output {
                Text(L("Script output")).font(.headline)
                ScrollView { Text(output.stdout + (output.stderr.isEmpty ? "" : "\n" + output.stderr)).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
            }
        }
    }
}
struct ExtensionsSettingsView: View {
    @ObservedObject var store: ExtensionStore
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Extensions are local subprocesses with your full user privileges, including file and network access. Process isolation is not a sandbox. Install only reviewed code. Preferences are plain text; credential fields and secret export are unsupported.")).font(.caption).foregroundStyle(.secondary)
            ForEach(store.manifests) { manifest in
                VStack(alignment: .leading) {
                    HStack {
                        Toggle(manifest.name, isOn: Binding(get: { manifest.enabled }, set: { store.setEnabled(id: manifest.id, enabled: $0) }))
                        Button(L("Remove")) { store.remove(id: manifest.id) }
                    }
                    Text(manifest.description).font(.caption)
                    Text(manifest.executable + " " + manifest.arguments.joined(separator: " ")).font(.caption).textSelection(.enabled)
                    ForEach(manifest.preferences) { preference in
                        TextField(preference.title, text: Binding(get: { store.preferences(id: manifest.id)[preference.id] ?? preference.defaultValue }, set: { store.setPreference(extensionID: manifest.id, key: preference.id, value: $0) }))
                    }
                }
            }
            Button(L("Import extension manifest…")) {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        let data = try Data(contentsOf: url)
                        guard data.count <= 262_144 else { throw AutomationFailure.invalid("Manifest exceeds 256 KB.") }
                        try store.install(JSONDecoder().decode(ExtensionManifest.self, from: data)); error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
    }
}
struct ExtensionBrowserView: View {
    @ObservedObject var store: ExtensionStore
    let extensionID: String
    @State private var query = ""
    @State private var selection: String?
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField(L("Search extension"), text: $query).onSubmit { store.search(id: extensionID, query: query) }
                Button(L("Search")) { store.search(id: extensionID, query: query) }
                if store.isRunning { ProgressView(); Button(L("Cancel")) { store.cancel() } }
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
            if let message = store.message { Text(message).textSelection(.enabled) }
            HStack(alignment: .top) {
                List(store.results, selection: $selection) { result in
                    VStack(alignment: .leading) { Text(result.title); if let subtitle = result.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) } }.tag(result.id)
                }.frame(minWidth: 200, minHeight: 200)
                if let result = store.results.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading) {
                        Text(result.title).font(.headline)
                        ScrollView { Text(result.detail ?? result.subtitle ?? "").textSelection(.enabled) }
                        ForEach(result.actions) { action in Button(action.title) { store.perform(id: extensionID, resultID: result.id, actionID: action.id) }.disabled(store.isRunning) }
                    }.frame(minWidth: 200)
                }
            }
        }.padding().onAppear { store.search(id: extensionID, query: "") }.onDisappear { store.cancel() }
    }
}
