import AppKit
import XCTest
@testable import Kebloop

@MainActor
final class ImmediateLaunchTests: XCTestCase {
    func testHidesBeforeLaunchAndRestoresQueryOnFailure() async throws {
        try await withLauncher { launcher, app, complete, attempts in
            launcher.show()
            launcher.setQuery("Launch Acceptance Fixture")
            XCTAssertEqual(launcher.resultIdentifiers.first, app.id)
            launcher.performSelected()
            XCTAssertFalse(launcher.isVisible)
            XCTAssertEqual(attempts(), 1)
            launcher.performSelected()
            XCTAssertEqual(attempts(), 1, "A repeated Return must not submit the hidden result again")
            complete(NSError(domain: "LaunchFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to launch"]))
            XCTAssertTrue(launcher.isVisible)
            XCTAssertEqual(launcher.currentQuery, "Launch Acceptance Fixture")
            XCTAssertEqual(launcher.resultIdentifiers.first, app.id)
        }
    }

    func testLateFailureDoesNotReplaceReopenedSession() async throws {
        try await withLauncher { launcher, _, complete, _ in
            launcher.show()
            launcher.setQuery("Launch Acceptance Fixture")
            launcher.performSelected()
            launcher.show()
            launcher.setQuery("New search")
            complete(NSError(domain: "LaunchFixture", code: 1))
            XCTAssertTrue(launcher.isVisible)
            XCTAssertEqual(launcher.currentQuery, "New search")
        }
    }

    private func withLauncher(_ body: (LauncherPanelController, IndexedApplication, (Error?) -> Void, () -> Int) throws -> Void) async throws {
        _ = NSApplication.shared
        let suite = "ImmediateLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "clipboardHistoryEnabled")
        let index = ApplicationIndex()
        for _ in 0..<200 {
            if !index.applications.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let app = try XCTUnwrap(index.applications.first)
        let aliases = AppAliasStore(defaults: defaults)
        XCTAssertNil(aliases.save(alias: "Launch Acceptance Fixture", for: app))
        let pasteboard = NSPasteboard(name: .init(suite))
        defer { pasteboard.releaseGlobally() }
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        defer { try? FileManager.default.removeItem(at: historyURL) }
        var completion: ((Error?) -> Void)?
        var attempts = 0
        let launcher = LauncherPanelController(index: index, quicklinks: QuicklinkStore(defaults: defaults),
            clipboard: ClipboardHistoryStore(defaults: defaults, pasteboard: pasteboard, storageURL: historyURL),
            aliases: aliases, ai: AIHandoffService(defaults: defaults, pasteboard: pasteboard),
            personalization: PersonalizationStore(defaults: defaults), appleShortcuts: AppleShortcutsService(defaults: defaults),
            launchApplication: { _, callback in
                attempts += 1
                completion = callback
            })
        defer { launcher.dismiss(restoreFocus: false) }
        try body(launcher, app, { completion?($0) }, { attempts })
    }
}
