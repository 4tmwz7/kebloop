import XCTest
@testable import Kebloop

final class AutomationConfigurationTests: XCTestCase {
    @MainActor
    func testPortableImportDisablesScriptsAndExtensionsAcrossProfilesAndExcludesPreferences() throws {
        let suite = "KebloopAutomationImport.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scripts = ScriptCommandStore(defaults: defaults)
        try scripts.save(ScriptCommand(id: "one", title: "One", description: "", executable: "/usr/bin/true", arguments: [], enabled: true))
        let extensions = ExtensionStore(defaults: defaults)
        try extensions.install(ExtensionManifest(id: "two", name: "Two", description: "", apiVersion: 1, executable: "/usr/bin/true", arguments: [], preferences: [ExtensionPreference(id: "text", title: "Text", defaultValue: "Default")]))
        extensions.setEnabled(id: "two", enabled: true)
        extensions.setPreference(extensionID: "two", key: "text", value: "PRIVATE-PREFERENCE-VALUE")
        let store = ConfigurationStore(defaults: defaults)
        let data = try store.exportData()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-PREFERENCE-VALUE"))
        let preview = try store.preview(data: data)
        XCTAssertTrue(preview.warnings.contains(where: { $0.contains("disabled") }))
        scripts.remove(id: "one"); extensions.remove(id: "two")
        try store.apply(preview: preview, mode: .merge)
        XCTAssertFalse(try XCTUnwrap(ScriptCommandStore(defaults: defaults).commands.first).enabled)
        XCTAssertFalse(try XCTUnwrap(ExtensionStore(defaults: defaults).manifests.first).enabled)
        let exported = try JSONDecoder().decode(PortableConfiguration.self, from: store.exportData())
        XCTAssertTrue(exported.profiles.allSatisfy { ($0.settings.scripts ?? []).allSatisfy { !$0.enabled } && ($0.settings.extensions ?? []).allSatisfy { !$0.enabled } })
    }
}


extension AutomationConfigurationTests {
    @MainActor
    func testReplaceImportAndProfileSwitchRequireReviewWithoutExecutingCode() throws {
        let suite = "KebloopAutomationProfileImport.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("kebloop-import-must-not-execute-\(UUID())")
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("kebloop-import-backup-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: marker); try? FileManager.default.removeItem(at: backup) }
        let scripts = ScriptCommandStore(defaults: defaults)
        try scripts.save(ScriptCommand(id: "touch", title: "Never run on import", description: "", executable: "/usr/bin/touch", arguments: [marker.path], enabled: true))
        let extensions = ExtensionStore(defaults: defaults)
        try extensions.install(ExtensionManifest(id: "touch-extension", name: "Never run on import", description: "", apiVersion: 1, executable: "/usr/bin/touch", arguments: [marker.path], preferences: []))
        extensions.setEnabled(id: "touch-extension", enabled: true)
        let store = ConfigurationStore(defaults: defaults)
        _ = try store.createProfile(name: "Second")
        let data = try store.exportData()
        let preview = try store.preview(data: data)
        XCTAssertEqual(preview.configuration.profiles.count, 2)
        XCTAssertTrue(preview.configuration.profiles.allSatisfy { ($0.settings.scripts ?? []).allSatisfy { !$0.enabled } && ($0.settings.extensions ?? []).allSatisfy { !$0.enabled } })
        try store.apply(preview: preview, mode: .replace, backupURL: backup)
        for profile in store.profiles {
            try store.switchProfile(id: profile.id)
            XCTAssertFalse(try XCTUnwrap(ScriptCommandStore(defaults: defaults).commands.first).enabled)
            XCTAssertFalse(try XCTUnwrap(ExtensionStore(defaults: defaults).manifests.first).enabled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }
    @MainActor
    func testMalformedAutomationImportDoesNotPartiallyChangeSettings() throws {
        let suite = "KebloopMalformedAutomationImport.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scripts = ScriptCommandStore(defaults: defaults)
        try scripts.save(ScriptCommand(id: "existing", title: "Existing", description: "", executable: "/usr/bin/true", arguments: [], enabled: true))
        let store = ConfigurationStore(defaults: defaults)
        let before = defaults.data(forKey: "scriptCommands")
        var configuration = try JSONDecoder().decode(PortableConfiguration.self, from: store.exportData())
        configuration.settings.scripts = [ScriptCommand(id: "bad", title: "Bad", description: "", executable: "relative/runtime", arguments: [], enabled: true)]
        XCTAssertThrowsError(try store.preview(data: JSONEncoder().encode(configuration)))
        XCTAssertEqual(defaults.data(forKey: "scriptCommands"), before)
        XCTAssertTrue(try XCTUnwrap(ScriptCommandStore(defaults: defaults).commands.first).enabled)
    }
}
