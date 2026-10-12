import AppKit
import XCTest
@testable import Kebloop

@MainActor final class MilestoneIntegrationTests: XCTestCase {
    func testClipboardActionMenuRemovesSelectedPinnedAndUnpinnedItemsWithoutLosingQuery() throws {
        _ = NSApplication.shared
        for pinned in [false, true] {
            let suite = "ClipboardActionIntegration.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let board = NSPasteboard(name: .init(suite)); defer { board.releaseGlobally() }
            let clipboard = ClipboardHistoryStore(defaults: defaults, pasteboard: board, storageURL: nil)
            clipboard.enabled = true
            for text in ["test clip keep", "test clip remove"] {
                board.clearContents(); board.setString(text, forType: .string); clipboard.poll()
            }
            let removedID = try XCTUnwrap(clipboard.items.first?.id)
            if pinned { XCTAssertTrue(clipboard.setPinned(true, for: removedID)) }
            let launcher = LauncherPanelController(index: ApplicationIndex(), quicklinks: QuicklinkStore(defaults: defaults), clipboard: clipboard, aliases: AppAliasStore(defaults: defaults), ai: AIHandoffService(defaults: defaults, pasteboard: board), personalization: PersonalizationStore(defaults: defaults), appleShortcuts: AppleShortcutsService(defaults: defaults), snippets: SnippetStore(defaults: defaults), scripts: ScriptCommandStore(defaults: defaults), extensions: ExtensionStore(defaults: defaults))
            launcher.executeCommand(id: "clipboard")
            launcher.setQuery("test clip")
            XCTAssertEqual(launcher.resultIdentifiers.first, "clipboard:" + removedID)
            launcher.showActions()
            XCTAssertTrue(launcher.isShowingActions)
            func key(_ code: UInt16) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            }
            XCTAssertTrue(launcher.handleActionKey(try key(125)))
            XCTAssertTrue(launcher.handleActionKey(try key(125)))
            XCTAssertTrue(launcher.handleActionKey(try key(36)))
            XCTAssertEqual(clipboard.items.map(\.text), ["test clip keep"])
            XCTAssertEqual(launcher.currentQuery, "test clip")
            XCTAssertEqual(launcher.resultIdentifiers, ["clipboard:" + clipboard.items[0].id])
            XCTAssertFalse(launcher.isShowingActions)
            XCTAssertTrue(launcher.isVisible)
            launcher.dismiss(restoreFocus: false); clipboard.enabled = false
        }
    }

    func testUserCommandsAreSearchableOnlyWhenEnabled() throws {
        _ = NSApplication.shared
        let suite = "MilestoneIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "clipboardHistoryEnabled")
        let snippets = SnippetStore(defaults: defaults), scripts = ScriptCommandStore(defaults: defaults), extensions = ExtensionStore(defaults: defaults)
        try snippets.save(name: "Unique Greeting", template: "Hello {name}")
        try scripts.save(ScriptCommand(id: "script-test", title: "Unique Script", description: "Test", executable: "/bin/echo", arguments: [], timeout: 1, enabled: false))
        try extensions.install(ExtensionManifest(id: "extension-test", name: "Unique Extension", description: "Test", apiVersion: 1, executable: "/bin/echo", arguments: [], preferences: []))
        let preferences = PersonalizationStore(defaults: defaults)
        preferences.settings.appsEnabled = false; preferences.settings.filesEnabled = false; preferences.settings.linksEnabled = false
        let board = NSPasteboard(name: .init(suite)); defer { board.releaseGlobally() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: url) }
        let launcher = LauncherPanelController(index: ApplicationIndex(), quicklinks: QuicklinkStore(defaults: defaults), clipboard: ClipboardHistoryStore(defaults: defaults, pasteboard: board, storageURL: url), aliases: AppAliasStore(defaults: defaults), ai: AIHandoffService(defaults: defaults, pasteboard: board), personalization: preferences, appleShortcuts: AppleShortcutsService(defaults: defaults), snippets: snippets, scripts: scripts, extensions: extensions)
        launcher.setQuery("Unique Greeting"); XCTAssertEqual(launcher.resultIdentifiers, ["snippet:" + snippets.snippets[0].id])
        launcher.setQuery("Unique Script"); XCTAssertFalse(launcher.resultIdentifiers.contains("script:script-test"))
        scripts.setEnabled(id: "script-test", enabled: true)
        launcher.setQuery("Unique Script"); XCTAssertEqual(launcher.resultIdentifiers.first, "script:script-test")
        launcher.setQuery("Unique Extension"); XCTAssertFalse(launcher.resultIdentifiers.contains("extension:extension-test"))
        extensions.setEnabled(id: "extension-test", enabled: true)
        launcher.setQuery("Unique Extension"); XCTAssertEqual(launcher.resultIdentifiers.first, "extension:extension-test")
        var invokedScripts: [String] = [], invokedExtensions: [String] = []
        launcher.onScript = { command, arguments in invokedScripts.append(command.id); XCTAssertTrue(arguments.isEmpty) }
        launcher.onExtension = { manifest in invokedExtensions.append(manifest.id) }
        launcher.executeCommand(id: "script:script-test"); launcher.executeCommand(id: "extension:extension-test")
        XCTAssertEqual(invokedScripts, ["script-test"]); XCTAssertEqual(invokedExtensions, ["extension-test"])
        scripts.setEnabled(id: "script-test", enabled: false); extensions.setEnabled(id: "extension-test", enabled: false)
        launcher.executeCommand(id: "script:script-test"); launcher.executeCommand(id: "extension:extension-test")
        XCTAssertEqual(invokedScripts.count, 1); XCTAssertEqual(invokedExtensions.count, 1)
        launcher.dismiss(restoreFocus: false)
        preferences.settings.commandsEnabled = false
        launcher.setQuery("Unique Greeting"); XCTAssertEqual(launcher.resultIdentifiers, [])
        XCTAssertTrue(LauncherCommand.settings.aliases.contains("ustawienia"))
        XCTAssertTrue(LauncherCommand.settings.aliases.contains("settings"))
    }
}
