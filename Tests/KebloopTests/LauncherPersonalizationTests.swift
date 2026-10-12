import AppKit
import XCTest
@testable import Kebloop

@MainActor
final class LauncherPersonalizationTests: XCTestCase {
    func testDisabledCategoriesHideCachedCandidatesAndWebFallback() throws {
        _ = NSApplication.shared
        let suite = "LauncherPersonalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "clipboardHistoryEnabled")
        let personalization = PersonalizationStore(defaults: defaults)
        personalization.settings.appsEnabled = false
        personalization.settings.filesEnabled = false
        personalization.settings.commandsEnabled = false
        personalization.settings.linksEnabled = false
        let links = QuicklinkStore(defaults: defaults)
        XCTAssertNil(links.save(name: "Example", target: "https://example.com"))
        let pasteboard = NSPasteboard(name: .init(suite))
        defer { pasteboard.releaseGlobally() }
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let launcher = LauncherPanelController(index: ApplicationIndex(), quicklinks: links,
            clipboard: ClipboardHistoryStore(defaults: defaults, pasteboard: pasteboard, storageURL: historyURL),
            aliases: AppAliasStore(defaults: defaults), ai: AIHandoffService(defaults: defaults, pasteboard: pasteboard),
            personalization: personalization, appleShortcuts: AppleShortcutsService(defaults: defaults))
        launcher.setQuery("Example")
        XCTAssertEqual(launcher.resultIdentifiers, [])
        launcher.setQuery("unmatched words")
        XCTAssertEqual(launcher.resultIdentifiers, [])
        personalization.settings.linksEnabled = true
        launcher.setQuery("Example")
        XCTAssertEqual(launcher.resultIdentifiers, ["link:" + links.links[0].id])
        launcher.showActions()
        XCTAssertTrue(launcher.isShowingActions)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        XCTAssertTrue(launcher.handleActionKey(escape))
        XCTAssertFalse(launcher.isShowingActions)
        XCTAssertEqual(launcher.currentQuery, "Example")
        XCTAssertEqual(launcher.resultIdentifiers, ["link:" + links.links[0].id])
        launcher.setQuery("")
        XCTAssertEqual(launcher.resultIdentifiers, [])
        personalization.settings.emptyMode = "favorites"
        let link = links.links[0]
        personalization.togglePin(PinnedResult(id: "link:" + link.id, name: link.name, path: link.target, kind: "quicklink"))
        launcher.setQuery("")
        XCTAssertEqual(launcher.resultIdentifiers, ["link:" + link.id])
    }
}
