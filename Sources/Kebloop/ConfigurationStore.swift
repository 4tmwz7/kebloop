import Combine
import Foundation

enum ConfigurationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct PortableSettings: Codable {
    var launcherShortcutID = "option"
    var launcherCustomShortcut: Shortcut? = nil
    var aliases: [String: String] = [:]
    var quicklinks: [Quicklink] = []
    var webSearches: [WebSearchTemplate] = []
    var appShortcuts: [AppShortcutBinding] = []
    var commandShortcuts: [CommandShortcutBinding] = []
    var selectedAppleShortcuts: [AppleShortcut] = []
    var personalization = PersonalizationSettings()
    var pins: [PinnedResult] = []
    var snippets: [Snippet]? = nil
    var scripts: [ScriptCommand]? = nil
    var extensions: [ExtensionManifest]? = nil

    func validate() throws {
        try personalization.validate()
        for command in scripts ?? [] { try command.validate() }; try unique((scripts ?? []).map(\.id))
        for manifest in extensions ?? [] { try manifest.validate() }; try unique((extensions ?? []).map(\.id))
        for snippet in snippets ?? [] { try snippet.validate() }; try unique((snippets ?? []).map(\.id))
        try Snippet.validateUniqueKeywords(snippets ?? [])
        guard let launcher = launcherShortcutID == "custom" ? launcherCustomShortcut : Shortcut.choices.first(where: { $0.id == launcherShortcutID }), launcher.keyCode <= 127, launcher.modifiers & 0x1900 != 0 else { throw ConfigurationError.invalid("Unknown launcher shortcut.") }
        guard !appShortcuts.contains(where: { $0.keyCode == launcher.keyCode && $0.modifiers == launcher.modifiers }),
              !commandShortcuts.contains(where: { $0.keyCode == launcher.keyCode && $0.modifiers == launcher.modifiers }) else { throw ConfigurationError.invalid("A command or application shortcut conflicts with the launcher.") }
        guard aliases.allSatisfy({ !$0.key.isEmpty && !Self.normalizedAlias($0.value).isEmpty && $0.value.count <= 100 }),
              Set(aliases.values.map(Self.normalizedAlias)).count == aliases.count,
              quicklinks.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.url != nil }),
              pins.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && ["application", "file", "quicklink", "command"].contains($0.kind) }) else {
            throw ConfigurationError.invalid("Invalid aliases, quicklinks, or pinned results.")
        }
        let keywords = quicklinks.map(\.keyword).filter { !$0.isEmpty } + webSearches.map(\.keyword)
        guard keywords.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isWhitespace }) }),
              webSearches.allSatisfy({ !$0.name.isEmpty && $0.target.contains("{query}") && $0.resolvedURL(argument: "test")?.isFileURL == false }),
              selectedAppleShortcuts.allSatisfy({ !$0.name.isEmpty && UUID(uuidString: $0.id) != nil }) else {
            throw ConfigurationError.invalid("Invalid web-search templates, keywords, or Apple Shortcuts.")
        }
        try unique(keywords.map { $0.lowercased() })
        try unique(quicklinks.map(\.id)); try unique(webSearches.map(\.id)); try unique(pins.map(\.id))
        try unique(appShortcuts.map(\.id)); try unique(commandShortcuts.map(\.id)); try unique(selectedAppleShortcuts.map(\.id))
        let automationIDs = (scripts ?? []).map(\.commandID) + (extensions ?? []).map(\.commandID)
        let commandIDs = Set(automationIDs + (snippets ?? []).map { "snippet:\($0.id)" } + LauncherCommand.allCases.map(\.id) + selectedAppleShortcuts.map { "apple:\($0.id)" } + quicklinks.map { "link:\($0.id)" })
        guard commandShortcuts.allSatisfy({ commandIDs.contains($0.id) }),
              appShortcuts.allSatisfy({ $0.appPath.hasPrefix("/") && !$0.appName.isEmpty && !$0.label.isEmpty }),
              commandShortcuts.allSatisfy({ !$0.label.isEmpty }) else { throw ConfigurationError.invalid("Unknown command identifiers or invalid application shortcuts.") }
        let combinations = appShortcuts.map { "\($0.keyCode):\($0.modifiers)" } + commandShortcuts.map { "\($0.keyCode):\($0.modifiers)" }
        try unique(combinations)
        guard appShortcuts.allSatisfy({ $0.keyCode <= 127 && $0.modifiers & 0x1900 != 0 }),
              commandShortcuts.allSatisfy({ $0.keyCode <= 127 && $0.modifiers & 0x1900 != 0 }) else {
            throw ConfigurationError.invalid("Shortcuts must include Command, Option, or Control.")
        }
    }
    private static func normalizedAlias(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private func unique(_ ids: [String]) throws {
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw ConfigurationError.invalid("Configuration contains duplicate identifiers or conflicting shortcuts.")
        }
    }
}

struct ConfigurationProfile: Codable, Identifiable {
    let id: String
    var name: String
    var settings: PortableSettings
}

struct PortableConfiguration: Codable {
    var version = 1
    var settings: PortableSettings
    var profiles: [ConfigurationProfile]
    var activeProfileID: String
}

struct ConfigurationPreview {
    let configuration: PortableConfiguration
    let summary: [String]
    let warnings: [String]
}

enum ConfigurationImportMode { case merge, replace }

@MainActor
final class ConfigurationStore: ObservableObject {
    @Published private(set) var profiles: [ConfigurationProfile]
    @Published private(set) var activeProfileID: String
    var activeProfileName: String { profiles.first { $0.id == activeProfileID }?.name ?? "Personal" }
    private let defaults: UserDefaults
    private let reload: () -> Void
    private let validateActivation: () throws -> Void

    init(defaults: UserDefaults = .standard, reload: @escaping () -> Void = {}, validateActivation: @escaping () throws -> Void = {}) {
        self.defaults = defaults
        self.reload = reload
        self.validateActivation = validateActivation
        profiles = defaults.data(forKey: "configurationProfiles").flatMap { try? JSONDecoder().decode([ConfigurationProfile].self, from: $0) } ?? []
        activeProfileID = defaults.string(forKey: "activeConfigurationProfile") ?? ""
        if profiles.isEmpty {
            let profile = ConfigurationProfile(id: UUID().uuidString, name: "Personal", settings: Self.capture(defaults))
            profiles = [profile]; activeProfileID = profile.id
        } else if !profiles.contains(where: { $0.id == activeProfileID }) { activeProfileID = profiles[0].id }
        persistProfiles()
    }

    func exportData(profileID: String? = nil) throws -> Data {
        saveActiveSnapshot()
        let configuration: PortableConfiguration
        if let profileID {
            guard let profile = profiles.first(where: { $0.id == profileID }) else { throw ConfigurationError.invalid("Profile not found.") }
            configuration = PortableConfiguration(settings: profile.settings, profiles: [profile], activeProfileID: profile.id)
        } else {
            configuration = PortableConfiguration(settings: Self.capture(defaults), profiles: profiles, activeProfileID: activeProfileID)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }

    func preview(data: Data) throws -> ConfigurationPreview {
        guard data.count <= 5_000_000 else { throw ConfigurationError.invalid("Configuration file is too large.") }
        var configuration: PortableConfiguration
        do { configuration = try JSONDecoder().decode(PortableConfiguration.self, from: data) }
        catch { throw ConfigurationError.invalid("The configuration file is malformed: \(error.localizedDescription)") }
        guard configuration.version == 1 else { throw ConfigurationError.invalid("Unsupported configuration version \(configuration.version).") }
        configuration.settings = Self.requireAutomationReview(configuration.settings)
        for index in configuration.profiles.indices { configuration.profiles[index].settings = Self.requireAutomationReview(configuration.profiles[index].settings) }
        try configuration.settings.validate()
        guard !configuration.profiles.isEmpty, Set(configuration.profiles.map(\.id)).count == configuration.profiles.count,
              configuration.profiles.contains(where: { $0.id == configuration.activeProfileID }),
              configuration.profiles.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ConfigurationError.invalid("Invalid profiles or active profile.")
        }
        for profile in configuration.profiles { try profile.settings.validate() }
        let settings = configuration.settings
        let current = Self.capture(defaults)
        var warnings: [String] = []
        if !(settings.scripts ?? []).isEmpty || !(settings.extensions ?? []).isEmpty { warnings.append("Imported scripts and extensions are disabled. Review executable paths and arguments in Settings before enabling. Local code runs with your privileges.") }
        for (path, alias) in settings.aliases where current.aliases[path] != nil && current.aliases[path] != alias { warnings.append("Alias conflict for \(path); merge keeps the existing alias.") }
        let currentKeywords = Set((current.quicklinks.map(\.keyword) + current.webSearches.map(\.keyword)).filter { !$0.isEmpty }.map { $0.lowercased() })
        for keyword in Set((settings.quicklinks.map(\.keyword) + settings.webSearches.map(\.keyword)).filter { !$0.isEmpty }) where currentKeywords.contains(keyword.lowercased()) {
            warnings.append("Keyword conflict: \(keyword). Merge validates the combined configuration before applying.")
        }
        for link in settings.quicklinks where current.quicklinks.contains(where: { $0.id == link.id && $0 != link }) {
            warnings.append("Quicklink conflict: \(link.name); merge keeps the existing quicklink.")
        }
        let payloads = [settings] + configuration.profiles.map(\.settings)
        var paths: [String] = []
        for payload in payloads {
            paths.append(contentsOf: payload.personalization.folders)
            paths.append(contentsOf: payload.personalization.hiddenApps)
            paths.append(contentsOf: payload.appShortcuts.map(\.appPath))
            paths.append(contentsOf: payload.aliases.keys)
            for pin in payload.pins where pin.kind == "file" || pin.kind == "application" { paths.append(pin.path) }
            for link in payload.quicklinks {
                if let url = link.url, url.isFileURL { paths.append(url.path) }
            }
        }
        for path in Set(paths).sorted() {
            let expanded = (path as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: expanded) { warnings.append("Unavailable on this Mac: \(path)") }
            else if !FileManager.default.isReadableFile(atPath: expanded) { warnings.append("Access is restricted on this Mac: \(path)") }
        }
        if !settings.selectedAppleShortcuts.isEmpty { warnings.append("Apple Shortcuts must be available on this Mac; refresh their list after importing.") }
        if !settings.appShortcuts.isEmpty || !settings.commandShortcuts.isEmpty { warnings.append("Shortcut availability is checked when applying; conflicts restore the previous configuration.") }
        warnings.append("Merge keeps current search and appearance preferences and conflicting identifiers; replace uses the imported values.")
        return ConfigurationPreview(configuration: configuration, summary: ["\((settings.snippets ?? []).count) snippets", "\((settings.scripts ?? []).count) scripts", "\((settings.extensions ?? []).count) extensions", "\(settings.aliases.count) aliases", "\(settings.quicklinks.count) quicklinks", "\(settings.appShortcuts.count + settings.commandShortcuts.count) shortcuts", "\(settings.pins.count) pins", "\(configuration.profiles.count) profiles"], warnings: warnings)
    }

    func apply(preview: ConfigurationPreview, mode: ConfigurationImportMode, backupURL: URL? = nil) throws {
        // Revalidate even if a preview was constructed programmatically.
        let validated = try self.preview(data: JSONEncoder().encode(preview.configuration))
        let old = Self.capture(defaults), oldProfiles = profiles, oldActive = activeProfileID
        let incoming = validated.configuration
        let next = mode == .replace ? incoming.settings : Self.merge(old, incoming.settings)
        try next.validate()
        if mode == .replace {
            let destination = backupURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Kebloop/Configuration Backups/\(UUID().uuidString).json")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try exportData().write(to: destination, options: .atomic)
        }
        do {
            try Self.write(next, to: defaults)
            if mode == .replace { profiles = incoming.profiles; activeProfileID = incoming.activeProfileID }
            else { profiles += incoming.profiles.filter { profile in !profiles.contains { $0.id == profile.id } } }
            saveActiveSnapshot(); persistProfiles(); reload(); try validateActivation()
        } catch {
            try? Self.write(old, to: defaults); profiles = oldProfiles; activeProfileID = oldActive; persistProfiles(); reload()
            throw error
        }
    }

    @discardableResult func createProfile(name: String) throws -> String {
        try validateName(name)
        saveActiveSnapshot()
        let profile = ConfigurationProfile(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), settings: Self.capture(defaults))
        profiles.append(profile); persistProfiles(); return profile.id
    }
    @discardableResult func duplicateProfile(id: String, name: String) throws -> String {
        try validateName(name); saveActiveSnapshot()
        guard let source = profiles.first(where: { $0.id == id }) else { throw ConfigurationError.invalid("Profile not found.") }
        let profile = ConfigurationProfile(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), settings: source.settings)
        profiles.append(profile); persistProfiles(); return profile.id
    }
    func renameProfile(id: String, name: String) throws {
        try validateName(name)
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ConfigurationError.invalid("Profile not found.") }
        profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); persistProfiles()
    }
    func deleteProfile(id: String) throws {
        guard profiles.count > 1 else { throw ConfigurationError.invalid("Keep at least one profile.") }
        if id == activeProfileID, let next = profiles.first(where: { $0.id != id }) { try switchProfile(id: next.id) }
        profiles.removeAll { $0.id == id }; persistProfiles()
    }
    func switchProfile(id: String) throws {
        guard id != activeProfileID else { return }
        guard let profile = profiles.first(where: { $0.id == id }) else { throw ConfigurationError.invalid("Profile not found.") }
        try profile.settings.validate(); saveActiveSnapshot()
        let previous = Self.capture(defaults), previousID = activeProfileID
        do {
            try Self.write(profile.settings, to: defaults); activeProfileID = id; reload(); try validateActivation(); persistProfiles()
        } catch {
            try? Self.write(previous, to: defaults); activeProfileID = previousID; reload(); persistProfiles(); throw error
        }
    }
    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else { throw ConfigurationError.invalid("Enter a profile name up to 100 characters.") }
    }
    private func saveActiveSnapshot() {
        if let index = profiles.firstIndex(where: { $0.id == activeProfileID }) { profiles[index].settings = Self.capture(defaults) }
        persistProfiles()
    }
    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "configurationProfiles") }
        defaults.set(activeProfileID, forKey: "activeConfigurationProfile")
    }
    private static func capture(_ defaults: UserDefaults) -> PortableSettings {
        func decode<T: Decodable>(_ key: String, fallback: T) -> T { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback }
        return PortableSettings(launcherShortcutID: defaults.string(forKey: "shortcut") ?? "option", launcherCustomShortcut: decode("launcherCustomShortcut", fallback: Optional<Shortcut>.none), aliases: defaults.dictionary(forKey: "appAliases") as? [String: String] ?? [:], quicklinks: decode("quicklinks", fallback: []), webSearches: decode("webSearches", fallback: [WebSearchTemplate(id: "duckduckgo", name: "DuckDuckGo", keyword: "web", target: "https://duckduckgo.com/?q={query}")]), appShortcuts: decode("appShortcuts", fallback: []), commandShortcuts: decode("commandShortcuts", fallback: []), selectedAppleShortcuts: decode("selectedAppleShortcuts", fallback: []), personalization: decode("personalizationSettings", fallback: PersonalizationSettings()), pins: decode("pinnedResults", fallback: []), snippets: decode("snippets", fallback: []), scripts: decode("scriptCommands", fallback: []), extensions: decode("extensionManifests", fallback: []))
    }
    private static func write(_ settings: PortableSettings, to defaults: UserDefaults) throws {
        // Encode everything first: malformed data can never leave partial preferences.
        let encoded = try ["launcherCustomShortcut": JSONEncoder().encode(settings.launcherCustomShortcut), "quicklinks": JSONEncoder().encode(settings.quicklinks), "webSearches": JSONEncoder().encode(settings.webSearches), "appShortcuts": JSONEncoder().encode(settings.appShortcuts), "commandShortcuts": JSONEncoder().encode(settings.commandShortcuts), "selectedAppleShortcuts": JSONEncoder().encode(settings.selectedAppleShortcuts), "personalizationSettings": JSONEncoder().encode(settings.personalization), "pinnedResults": JSONEncoder().encode(settings.pins), "snippets": JSONEncoder().encode(settings.snippets ?? []), "scriptCommands": JSONEncoder().encode(settings.scripts ?? []), "extensionManifests": JSONEncoder().encode(settings.extensions ?? [])]
        defaults.set(settings.launcherShortcutID, forKey: "shortcut")
        defaults.set(settings.aliases, forKey: "appAliases")
        for (key, data) in encoded { defaults.set(data, forKey: key) }
    }
    private static func requireAutomationReview(_ settings: PortableSettings) -> PortableSettings {
        var result = settings
        result.scripts = settings.scripts?.map { var command = $0; command.enabled = false; return command }
        result.extensions = settings.extensions?.map { var manifest = $0; manifest.enabled = false; return manifest }
        return result
    }
    private static func merge(_ current: PortableSettings, _ incoming: PortableSettings) -> PortableSettings {
        func union<T: Identifiable>(_ current: [T], _ incoming: [T]) -> [T] { current + incoming.filter { item in !current.contains { $0.id == item.id } } }
        var merged = current
        merged.scripts = union(current.scripts ?? [], incoming.scripts ?? [])
        merged.extensions = union(current.extensions ?? [], incoming.extensions ?? [])
        merged.snippets = union(current.snippets ?? [], incoming.snippets ?? [])
        merged.aliases.merge(incoming.aliases) { existing, _ in existing }
        merged.quicklinks = union(current.quicklinks, incoming.quicklinks); merged.webSearches = union(current.webSearches, incoming.webSearches)
        merged.appShortcuts = union(current.appShortcuts, incoming.appShortcuts); merged.commandShortcuts = union(current.commandShortcuts, incoming.commandShortcuts)
        merged.selectedAppleShortcuts = union(current.selectedAppleShortcuts, incoming.selectedAppleShortcuts); merged.pins = union(current.pins, incoming.pins)
        return merged
    }
}
