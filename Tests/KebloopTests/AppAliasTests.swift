import XCTest
@testable import Kebloop

final class AppAliasTests: XCTestCase {
    @MainActor
    func testAliasesTrimPersistAndCanBeRemoved() throws {
        let suite = "KebloopAppAliasTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = IndexedApplication(name: "Ghostty", path: "/Applications/Ghostty.app")
        let store = AppAliasStore(defaults: defaults)

        XCTAssertNil(store.save(alias: "  terminal  ", for: app))
        XCTAssertEqual(store.alias(for: app), "terminal")
        XCTAssertEqual(AppAliasStore(defaults: defaults).alias(for: app), "terminal")

        store.remove(for: app)
        XCTAssertNil(AppAliasStore(defaults: defaults).alias(for: app))
    }

    @MainActor
    func testAliasesRejectNormalizedDuplicatesAndOverlongValues() {
        let suite = "KebloopAppAliasTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ghostty = IndexedApplication(name: "Ghostty", path: "/Applications/Ghostty.app")
        let terminal = IndexedApplication(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app")
        let store = AppAliasStore(defaults: defaults)

        XCTAssertNil(store.save(alias: "Résumé", for: ghostty))
        XCTAssertNotNil(store.save(alias: "resume", for: terminal))
        XCTAssertNil(store.alias(for: terminal))
        XCTAssertNotNil(store.save(alias: String(repeating: "a", count: 101), for: ghostty))
        XCTAssertEqual(store.alias(for: ghostty), "Résumé")
    }
}
