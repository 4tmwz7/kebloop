import Combine
import Foundation

struct PersonalizationSettings: Codable, Equatable {
    var appsEnabled = true
    var filesEnabled = true
    var linksEnabled = true
    var commandsEnabled = true
    var folders = [FileManager.default.homeDirectoryForCurrentUser.path]
    var exclusions: [String] = []
    var hiddenApps: [String] = []
    var emptyMode = "frequent"
    var appearance = "system"
    var textSize: Double = 14
    var panelWidth: Double = 560
    var compact = false
    var transparency = true
    var showShortcutHints = true
    var placement = "pointer"
    var displayID = ""

    private enum CodingKeys: String, CodingKey {
        case appsEnabled, filesEnabled, linksEnabled, commandsEnabled, folders, exclusions, hiddenApps, emptyMode
        case appearance, textSize, panelWidth, compact, transparency, showShortcutHints, placement, displayID
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        appsEnabled = try values.decodeIfPresent(Bool.self, forKey: .appsEnabled) ?? defaults.appsEnabled
        filesEnabled = try values.decodeIfPresent(Bool.self, forKey: .filesEnabled) ?? defaults.filesEnabled
        linksEnabled = try values.decodeIfPresent(Bool.self, forKey: .linksEnabled) ?? defaults.linksEnabled
        commandsEnabled = try values.decodeIfPresent(Bool.self, forKey: .commandsEnabled) ?? defaults.commandsEnabled
        folders = try values.decodeIfPresent([String].self, forKey: .folders) ?? defaults.folders
        exclusions = try values.decodeIfPresent([String].self, forKey: .exclusions) ?? defaults.exclusions
        hiddenApps = try values.decodeIfPresent([String].self, forKey: .hiddenApps) ?? defaults.hiddenApps
        emptyMode = try values.decodeIfPresent(String.self, forKey: .emptyMode) ?? defaults.emptyMode
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? defaults.appearance
        textSize = try values.decodeIfPresent(Double.self, forKey: .textSize) ?? defaults.textSize
        panelWidth = try values.decodeIfPresent(Double.self, forKey: .panelWidth) ?? defaults.panelWidth
        compact = try values.decodeIfPresent(Bool.self, forKey: .compact) ?? defaults.compact
        transparency = try values.decodeIfPresent(Bool.self, forKey: .transparency) ?? defaults.transparency
        showShortcutHints = try values.decodeIfPresent(Bool.self, forKey: .showShortcutHints) ?? defaults.showShortcutHints
        placement = try values.decodeIfPresent(String.self, forKey: .placement) ?? defaults.placement
        displayID = try values.decodeIfPresent(String.self, forKey: .displayID) ?? defaults.displayID
    }

    func validate() throws {
        guard ["frequent", "recent", "favorites"].contains(emptyMode),
              ["system", "light", "dark"].contains(appearance),
              ["pointer", "active", "display"].contains(placement),
              textSize.isFinite, (11...24).contains(textSize),
              panelWidth.isFinite, (420...1000).contains(panelWidth),
              (folders + exclusions + hiddenApps).allSatisfy({ $0.hasPrefix("/") || $0.hasPrefix("~/") }) else {
            throw ConfigurationError.invalid("Invalid search or appearance preferences.")
        }
    }
}

struct PinnedResult: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var path: String
    var kind: String
}

@MainActor
final class PersonalizationStore: ObservableObject {
    @Published var settings: PersonalizationSettings { didSet { persist() } }
    @Published private(set) var pins: [PinnedResult] { didSet { persist() } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: "personalizationSettings").flatMap { try? JSONDecoder().decode(PersonalizationSettings.self, from: $0) } ?? PersonalizationSettings()
        pins = defaults.data(forKey: "pinnedResults").flatMap { try? JSONDecoder().decode([PinnedResult].self, from: $0) } ?? []
    }

    func reload() {
        // Read both snapshots before either publisher persists its new value.
        let nextSettings = defaults.data(forKey: "personalizationSettings").flatMap { try? JSONDecoder().decode(PersonalizationSettings.self, from: $0) } ?? PersonalizationSettings()
        let nextPins = defaults.data(forKey: "pinnedResults").flatMap { try? JSONDecoder().decode([PinnedResult].self, from: $0) } ?? []
        settings = nextSettings
        pins = nextPins
    }
    func reset() { settings = PersonalizationSettings(); pins = [] }
    func isPinned(id: String) -> Bool { pins.contains { $0.id == id } }
    func togglePin(_ result: PinnedResult) {
        if isPinned(id: result.id) { removePin(id: result.id) } else { pins.append(result) }
    }
    func removePin(id: String) { pins.removeAll { $0.id == id } }
    func allowsFile(path: String) -> Bool {
        guard settings.filesEnabled else { return false }
        let normalized = Self.normalized(path)
        return settings.folders.contains { Self.contains(normalized, in: $0) }
            && !settings.exclusions.contains { Self.contains(normalized, in: $0) }
    }
    nonisolated static func contains(_ path: String, in folder: String) -> Bool {
        let root = normalized(folder)
        return root == "/" || path == root || path.hasPrefix(root + "/")
    }
    nonisolated private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "personalizationSettings") }
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: "pinnedResults") }
    }
}
