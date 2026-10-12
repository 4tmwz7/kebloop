import XCTest
@testable import Kebloop

final class ConfigurationTests: XCTestCase {
    @MainActor
    func testFolderBoundariesAndPersistence() throws {
        let suite = "KebloopConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PersonalizationStore(defaults: defaults)
        store.settings.folders = ["/Users/example/Documents"]
        store.settings.exclusions = ["/Users/example/Documents/Private"]
        XCTAssertTrue(store.allowsFile(path: "/Users/example/Documents/report.txt"))
        XCTAssertFalse(store.allowsFile(path: "/Users/example/Documents-old/report.txt"))
        XCTAssertFalse(store.allowsFile(path: "/Users/example/Documents/Private/report.txt"))
        XCTAssertTrue(store.allowsFile(path: "/Users/example/Documents/Privateer/report.txt"))
        let pin = PinnedResult(id: "file:/Users/example/Documents/report.txt", name: "Report", path: "/Users/example/Documents/report.txt", kind: "file")
        store.togglePin(pin)
        XCTAssertEqual(PersonalizationStore(defaults: defaults).pins, [pin])
        store.togglePin(pin)
        XCTAssertTrue(store.pins.isEmpty)
        defaults.set(try JSONEncoder().encode([pin]), forKey: "pinnedResults")
        var replacement = store.settings
        replacement.appearance = "dark"
        defaults.set(try JSONEncoder().encode(replacement), forKey: "personalizationSettings")
        store.reload()
        XCTAssertEqual(store.settings.appearance, "dark")
        XCTAssertEqual(store.pins, [pin])
    }

    @MainActor
    func testRoundTripPrivacyExclusionAndReplaceBackup() throws {
        let suite = "KebloopConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/Applications/Test.app": "test"], forKey: "appAliases")
        defaults.set("secret clipboard", forKey: "clipboardHistory")
        defaults.set(true, forKey: "launchAtLogin")
        let store = ConfigurationStore(defaults: defaults)
        let exported = try store.exportData()
        let text = try XCTUnwrap(String(data: exported, encoding: .utf8))
        XCTAssertFalse(text.contains("secret clipboard")); XCTAssertFalse(text.contains("launchAtLogin"))
        defaults.set(["/Applications/Other.app": "other"], forKey: "appAliases")
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: backup) }
        try store.apply(preview: store.preview(data: exported), mode: .replace, backupURL: backup)
        XCTAssertEqual(defaults.dictionary(forKey: "appAliases") as? [String: String], ["/Applications/Test.app": "test"])
        let savedBackup = try JSONDecoder().decode(PortableConfiguration.self, from: Data(contentsOf: backup))
        XCTAssertEqual(savedBackup.settings.aliases, ["/Applications/Other.app": "other"])
        XCTAssertEqual(defaults.string(forKey: "clipboardHistory"), "secret clipboard")
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
    }

    @MainActor
    func testValidationAndActivationFailureDoNotPartiallyWrite() throws {
        let suite = "KebloopConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/Applications/Original.app": "original"], forKey: "appAliases")
        let store = ConfigurationStore(defaults: defaults, validateActivation: { throw ConfigurationError.invalid("Shortcut unavailable") })
        var configuration = try JSONDecoder().decode(PortableConfiguration.self, from: store.exportData())
        configuration.version = 99
        XCTAssertThrowsError(try store.preview(data: JSONEncoder().encode(configuration)))
        configuration.version = 1
        configuration.settings.aliases = ["/Applications/New.app": "new"]
        let preview = try store.preview(data: JSONEncoder().encode(configuration))
        XCTAssertThrowsError(try store.apply(preview: preview, mode: .merge))
        XCTAssertEqual(defaults.dictionary(forKey: "appAliases") as? [String: String], ["/Applications/Original.app": "original"])
        XCTAssertThrowsError(try store.preview(data: Data("{}".utf8)))
    }

    @MainActor
    func testProfileSnapshotsSwitchAndRollback() throws {
        let suite = "KebloopConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/Applications/Personal.app": "personal"], forKey: "appAliases")
        var fail = false
        let store = ConfigurationStore(defaults: defaults, validateActivation: { if fail { throw ConfigurationError.invalid("Unavailable shortcut") } })
        let personal = store.activeProfileID
        let work = try store.createProfile(name: "Work")
        try store.switchProfile(id: work)
        defaults.set(["/Applications/Work.app": "work"], forKey: "appAliases")
        fail = true
        XCTAssertThrowsError(try store.switchProfile(id: personal))
        XCTAssertEqual(store.activeProfileID, work)
        XCTAssertEqual(defaults.dictionary(forKey: "appAliases") as? [String: String], ["/Applications/Work.app": "work"])
        fail = false
        try store.switchProfile(id: personal)
        XCTAssertEqual(defaults.dictionary(forKey: "appAliases") as? [String: String], ["/Applications/Personal.app": "personal"])
        try store.deleteProfile(id: work)
        XCTAssertThrowsError(try store.deleteProfile(id: personal))
    }
    func testPortableValidationRejectsTemplatesKeywordsAndUnknownCommands() throws {
        var settings = PortableSettings()
        settings.webSearches = [WebSearchTemplate(id: "bad", name: "Bad", keyword: "web", target: "https://{query}.example.com")]
        XCTAssertThrowsError(try settings.validate())
        settings.webSearches = [WebSearchTemplate(id: "web", name: "Web", keyword: "gh", target: "https://example.com/?q={query}")]
        settings.quicklinks = [Quicklink(id: "gh", name: "GitHub", target: "https://github.com", keyword: "GH")]
        XCTAssertThrowsError(try settings.validate())
        settings.quicklinks = []
        settings.commandShortcuts = [CommandShortcutBinding(id: "unknown", keyCode: 4, modifiers: 256, label: "Command H")]
        XCTAssertThrowsError(try settings.validate())
        settings.commandShortcuts = []
        settings.selectedAppleShortcuts = [AppleShortcut(id: "not-a-uuid", name: "Broken")]
        XCTAssertThrowsError(try settings.validate())
    }

    func testNewHintPreferencePreservesOlderSearchChoices() throws {
        let old = Data(#"{"appsEnabled":false,"appearance":"dark","folders":["/Users/example/Documents"]}"#.utf8)
        var settings = try JSONDecoder().decode(PersonalizationSettings.self, from: old)
        XCTAssertFalse(settings.appsEnabled)
        XCTAssertEqual(settings.appearance, "dark")
        XCTAssertEqual(settings.folders, ["/Users/example/Documents"])
        XCTAssertTrue(settings.showShortcutHints)
        settings.showShortcutHints = false
        let restored = try JSONDecoder().decode(PersonalizationSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.showShortcutHints)
    }

}
