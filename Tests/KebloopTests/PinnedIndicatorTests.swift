import AppKit
import XCTest
@testable import Kebloop

@MainActor final class PinnedIndicatorTests: XCTestCase {
    func testPinnedAppHasVisibleBadgeAndAccessibleStatusAndUnpinRemovesBoth() async throws {
        _ = NSApplication.shared
        let suite = "PinnedIndicator.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "clipboardHistoryEnabled")
        let index = ApplicationIndex()
        for _ in 0..<200 {
            if !index.applications.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let app = try XCTUnwrap(index.applications.first)
        let aliases = AppAliasStore(defaults: defaults)
        let query = "PinnedIndicatorFixture"
        XCTAssertNil(aliases.save(alias: query, for: app))
        let personalization = PersonalizationStore(defaults: defaults)
        personalization.settings.filesEnabled = false
        let board = NSPasteboard(name: .init(suite)); defer { board.releaseGlobally() }
        let launcher = LauncherPanelController(index: index, quicklinks: QuicklinkStore(defaults: defaults), clipboard: ClipboardHistoryStore(defaults: defaults, pasteboard: board, storageURL: nil), aliases: aliases, ai: AIHandoffService(defaults: defaults, pasteboard: board), personalization: personalization)
        defer { launcher.dismiss(restoreFocus: false) }
        launcher.show(); launcher.setQuery(query)
        func row() throws -> NSButton {
            try XCTUnwrap(NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(descendants).compactMap { $0 as? NSButton }.first { ($0.accessibilityLabel() ?? "").hasPrefix(app.name + ",") })
        }
        XCTAssertFalse(try row().subviews.contains { $0.identifier?.rawValue == "favorite-pin" })
        let pin = PinnedResult(id: app.id, name: app.name, path: app.path, kind: "application")
        personalization.togglePin(pin); launcher.setQuery(query)
        XCTAssertTrue(try row().subviews.contains { $0.identifier?.rawValue == "favorite-pin" })
        XCTAssertTrue(try row().accessibilityLabel()?.contains(L("Pinned to Favorites")) == true)
        personalization.togglePin(pin); launcher.setQuery(query)
        XCTAssertFalse(try row().subviews.contains { $0.identifier?.rawValue == "favorite-pin" })
        XCTAssertFalse(try row().accessibilityLabel()?.contains(L("Pinned to Favorites")) == true)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
