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

extension QuicklinkTests {
    func testLegacyDecodeAndTemplateEncoding() throws {
        let data = Data(#"{"id":"old","name":"Old","target":"https://example.com"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Quicklink.self, from: data).keyword, "")
        let url = try XCTUnwrap(Quicklink.destination("https://example.com/?q={query}", argument: "Łódź & cats/+?#"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Łódź & cats/+?#")
        XCTAssertNil(Quicklink.destination("https://{query}.example.com"))
        XCTAssertNil(Quicklink.destination("https://example.com/{unknown}"))
        XCTAssertNil(Quicklink.destination("/tmp/{query}"))
    }
    @MainActor
    func testKeywordConflictsAndExplicitResolution() throws {
        let suite = "KebloopTemplates.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuicklinkStore(defaults: defaults)
        XCTAssertNil(store.save(name: "GitHub", target: "https://github.com/search?q={query}", keyword: "gh"))
        XCTAssertNotNil(store.save(name: "Conflict", target: "https://example.com", keyword: "GH"))
        XCTAssertNotNil(store.saveWebSearch(name: "Conflict", keyword: "gh", target: "https://example.com/?q={query}"))
        XCTAssertNotNil(store.saveWebSearch(name: "Invalid", keyword: "bad", target: "https://example.com"))
        let resolved = try XCTUnwrap(store.resolve(query: "gh hello world"))
        XCTAssertEqual(resolved.argument, "hello world")
        XCTAssertEqual(resolved.link.keyword, "gh")
        XCTAssertNil(store.resolve(query: "unknown query"))
        XCTAssertNotNil(store.fallbackURL(query: "unknown query"))
        XCTAssertEqual(QuicklinkStore(defaults: defaults).links.first?.keyword, "gh")
    }
}
