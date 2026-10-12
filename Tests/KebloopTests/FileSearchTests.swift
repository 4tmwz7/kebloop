import Combine
import XCTest
@testable import Kebloop

final class FileSearchTests: XCTestCase {
    func testCachedNarrowingOnlyReturnsMatchingNames() {
        var cache = FileSearchCache()
        cache.store([file("Résumé.pdf"), file("Research.txt"), file("report.txt")], for: "re")
        XCTAssertEqual(cache.matching("resume").map(\.name), ["Résumé.pdf"])
        XCTAssertEqual(cache.matching("rese").map(\.name), ["Research.txt"])
        XCTAssertTrue(cache.matching("other").isEmpty)
        XCTAssertTrue(cache.matching("").isEmpty)
    }

    func testCacheIsBoundedAndUpdatesExistingQueries() {
        var cache = FileSearchCache()
        cache.store((0..<60).map { file("alpha-\($0)") }, for: "alpha")
        XCTAssertEqual(cache.matching("alpha").count, 40)
        cache.store([file("alpha-new")], for: "alpha")
        XCTAssertEqual(cache.matching("alpha").map(\.name), ["alpha-new"])
        for index in 0..<12 { cache.store([file("query\(index)")], for: "query\(index)") }
        XCTAssertTrue(cache.matching("alpha").isEmpty)
    }

    func testHiddenFilesAndApplicationContentsAreExcluded() {
        for path in ["/Users/me/.secret", "/Users/me/.config/file", "/Applications/Ghostty.app",
                     "/Applications/Ghostty.app/Contents/Info.plist", "/Users/me/Tool.APP/file",
                     "/Users/me/Plug.plugin/Info.plist", "/Users/me/Library/Test.framework/Header.h"] {
            XCTAssertFalse(FileSearchResult.isVisibleFile(path: path), path)
        }
        XCTAssertTrue(FileSearchResult.isVisibleFile(path: "/Users/me/Documents/application.txt"))
        XCTAssertTrue(FileSearchResult.isVisibleFile(path: "/Users/me/Documents/project.app-notes.txt"))
    }

    func testLibraryAndDependencyContentsAreExcluded() {
        XCTAssertFalse(FileSearchResult.isVisibleFile(path: FileSearchResult.libraryPath))
        XCTAssertFalse(FileSearchResult.isVisibleFile(path: FileSearchResult.libraryPath + "/Caches/terminal.txt"))
        XCTAssertFalse(FileSearchResult.isVisibleFile(path: "/Users/me/project/node_modules/terminal/index.js"))
        XCTAssertFalse(FileSearchResult.isVisibleFile(path: "/Users/me/project/node_modules"))
        XCTAssertTrue(FileSearchResult.isVisibleFile(path: "/Users/me/Documents/Library-notes.txt"))
    }

    func testExactAndPrefixNamesRankBeforeSubstringWithUserFolderBoost() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let exact = FileSearchResult(name: "Terminal.pdf", path: home + "/Downloads/Terminal.pdf")
        let exactOther = FileSearchResult(name: "Terminal.txt", path: home + "/project/Terminal.txt")
        let prefix = FileSearchResult(name: "terminal-KebloopVerification.txt", path: home + "/Desktop/terminal-KebloopVerification.txt")
        let substring = FileSearchResult(name: "a-terminal.txt", path: home + "/Documents/a-terminal.txt")
        let files = [substring, prefix, exactOther, exact]
        XCTAssertEqual(FileSearchResult.ranked(files, for: "terminal"), [exact, exactOther, prefix, substring])
        XCTAssertEqual(FileSearchResult.ranked(Array(files.reversed()), for: "terminal"), [exact, exactOther, prefix, substring])
    }

    @MainActor
    func testEmptySearchCancelsPendingSearchAndClearsRows() async throws {
        let service = FileSearchService()
        service.search("old query")
        XCTAssertTrue(service.isSearching)
        service.search("   ")
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertFalse(service.isSearching)
        XCTAssertTrue(service.results.isEmpty)
    }

    @MainActor
    func testRepeatedStopDoesNotPublishUnchangedState() {
        let service = FileSearchService()
        var resultUpdates = 0
        var statusUpdates = 0
        let rows = service.$results.dropFirst().sink { _ in resultUpdates += 1 }
        let status = service.$isSearching.dropFirst().sink { _ in statusUpdates += 1 }
        service.stop()
        service.stop()
        XCTAssertEqual(resultUpdates, 0)
        XCTAssertEqual(statusUpdates, 0)
        service.search("pending")
        service.stop()
        service.stop()
        XCTAssertEqual(resultUpdates, 0)
        XCTAssertEqual(statusUpdates, 2)
        withExtendedLifetime((rows, status)) {}
    }

    private func file(_ name: String) -> FileSearchResult {
        FileSearchResult(name: name, path: "/Users/test/Documents/\(name)")
    }
}
