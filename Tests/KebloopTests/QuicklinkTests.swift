import XCTest
@testable import Kebloop

final class QuicklinkTests: XCTestCase {
    func testWebAndLocalDestinations() {
        XCTAssertEqual(Quicklink.destination(" https://example.com/search?q=swift ")?.host, "example.com")
        XCTAssertEqual(Quicklink.destination("http://localhost:3000")?.scheme, "http")
        XCTAssertEqual(Quicklink.destination("/Applications")?.path, "/Applications")
        XCTAssertEqual(Quicklink.destination("~/Documents")?.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path)
    }

    func testUnsafeAndInvalidTargetsAreRejected() {
        for target in ["javascript:alert(1)", "data:text/plain,Hello", "file:///etc/passwd", "mailto:test@example.com", "https://", "example.com", "./Documents", "", "open /Applications"] {
            XCTAssertNil(Quicklink.destination(target), target)
        }
    }

    @MainActor
    func testQuicklinksPersistEditAndRemove() throws {
        let suite = "KebloopQuicklinkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuicklinkStore(defaults: defaults)
        XCTAssertNotNil(store.save(name: "  ", target: "https://example.com"))
        XCTAssertNotNil(store.save(name: "Bad", target: "javascript:alert(1)"))
        XCTAssertTrue(store.links.isEmpty)
        XCTAssertNil(store.save(name: " Docs ", target: " https://example.com/docs "))
        let id = try XCTUnwrap(store.links.first?.id)
        XCTAssertEqual(store.links.first?.name, "Docs")
        XCTAssertEqual(QuicklinkStore(defaults: defaults).links.first?.id, id)
        XCTAssertNil(store.save(id: id, name: "Documents", target: "~/Documents"))
        XCTAssertEqual(store.links.count, 1)
        XCTAssertEqual(QuicklinkStore(defaults: defaults).links.first?.target, "~/Documents")
        store.remove(id: id)
        XCTAssertTrue(QuicklinkStore(defaults: defaults).links.isEmpty)
    }
}
