import XCTest
@testable import KebloopCore

final class SearchTests: XCTestCase {
    private let search = AppSearch()

    func testExactAndPrefixMatchesStayAheadOfFuzzyMatches() {
        let entries = [
            entry("safari", "Safari"),
            entry("preview", "Safari Technology Preview"),
            entry("fuzzy", "System Activity File Archive")
        ]

        let results = search.ranked(
            query: "safari",
            entries: entries,
            usage: ["fuzzy": 50_000]
        )

        XCTAssertEqual(results.map(\.id), ["safari", "preview", "fuzzy"])
    }

    func testExactAliasOutranksExactApplicationNameEvenWithHighUsage() {
        let results = search.ranked(
            query: "terminal",
            entries: [
                AppSearchEntry(id: "terminal", name: "Terminal", path: "/System/Applications/Utilities/Terminal.app"),
                AppSearchEntry(id: "ghostty", name: "Ghostty", path: "/Applications/Ghostty.app", aliases: ["terminal"])
            ],
            usage: ["terminal": 50_000]
        )

        XCTAssertEqual(results.map(\.id), ["ghostty", "terminal"])
    }

    func testAliasPrefixRanksBelowExactNameAndAboveNamePrefix() {
        let results = search.ranked(
            query: "term",
            entries: [
                AppSearchEntry(id: "alias", name: "Ghostty", path: "/Applications/Ghostty.app", aliases: ["terminal"]),
                entry("exact", "Term"),
                entry("prefix", "Terminal Utility")
            ]
        )

        XCTAssertEqual(results.map(\.id), ["exact", "alias", "prefix"])
    }

    func testAliasesUseCaseAndDiacriticInsensitiveMatching() {
        let results = search.ranked(
            query: "resume",
            entries: [AppSearchEntry(id: "notes", name: "Notes", path: "/Applications/Notes.app", aliases: ["Résumé"]) ]
        )

        XCTAssertEqual(results.map(\.id), ["notes"])
    }

    func testSearchIgnoresCaseAndDiacritics() {
        let results = search.ranked(
            query: "CAFE",
            entries: [entry("cafe", "Café"), entry("time", "CafeTime")]
        )

        XCTAssertEqual(results.map(\.id), ["cafe", "time"])
    }

    func testWordPrefixesCanMatchWordsAfterTheFirst() {
        let results = search.ranked(
            query: "sto co",
            entries: [
                entry("visual-studio", "Visual Studio Code"),
                entry("studio-code", "Studio Code")
            ]
        )

        XCTAssertEqual(results.map(\.id), ["studio-code", "visual-studio"])
    }

    func testFuzzySubsequenceMatchesInitials() {
        let results = search.ranked(
            query: "vsc",
            entries: [entry("vscode", "Visual Studio Code"), entry("other", "TextEdit")]
        )

        XCTAssertEqual(results.map(\.id), ["vscode"])
    }

    func testUsageOrdersTheUnfilteredList() {
        let entries = [entry("mail", "Mail"), entry("safari", "Safari")]

        let results = search.ranked(query: "   ", entries: entries, usage: ["safari": 4, "mail": 1])

        XCTAssertEqual(results.map(\.id), ["safari", "mail"])
    }

    func testDuplicateNamesUseStablePaths() {
        let entries = [entry("b", "Safari"), entry("a", "Safari")]
        XCTAssertEqual(search.ranked(query: "saf", entries: entries).map(\.id), ["a", "b"])
    }

    func testThousandAppSearchPerformance() throws {
        guard ProcessInfo.processInfo.environment["KEBLOOP_PROFILE"] == "1" else {
            throw XCTSkip("Set KEBLOOP_PROFILE=1 to run the search timing sample.")
        }

        let entries = (0..<1000).map { entry("app-\($0)", "Application Tool \($0)") }
        measure {
            let results = search.ranked(query: "at", entries: entries)
            XCTAssertEqual(results.count, 1000)
        }
    }

    private func entry(_ id: String, _ name: String) -> AppSearchEntry {
        AppSearchEntry(id: id, name: name, path: "/Applications/\(name).app")
    }
}
