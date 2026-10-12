import XCTest
@testable import KebloopCore

final class EmojiTests: XCTestCase {
    func testCatalogHasUniqueSymbolsAndUsefulBreadth() {
        XCTAssertGreaterThanOrEqual(EmojiCatalog.entries.count, 150)
        XCTAssertEqual(Set(EmojiCatalog.entries.map(\.id)).count, EmojiCatalog.entries.count)
        XCTAssertTrue(Set(EmojiCatalog.entries.map(\.category)).isSuperset(of: ["Smileys", "Animals", "Food", "Symbols", "Flags"]))
    }

    func testSearchFindsNamesAndRanksSpecificMatchesFirst() {
        let results = EmojiCatalog.search("heart")

        XCTAssertEqual(results.first?.symbol, "🫶")
        XCTAssertTrue(results.contains { $0.symbol == "💔" })
    }

    func testSearchFindsAliasesWithoutCaseSensitivity() {
        let results = EmojiCatalog.search("ROFL")

        XCTAssertEqual(results.first?.symbol, "🤣")
    }

    func testSearchFindsCategoryAndEmojiSymbol() {
        XCTAssertTrue(EmojiCatalog.search("japan").contains { $0.symbol == "🇯🇵" })
        XCTAssertEqual(EmojiCatalog.search("🧋").first?.symbol, "🧋")
    }

    func testEmptySearchReturnsWholeCatalogAndUnknownSearchReturnsNothing() {
        XCTAssertEqual(EmojiCatalog.search("  ").count, EmojiCatalog.entries.count)
        XCTAssertTrue(EmojiCatalog.search("unfindable-emoji-query").isEmpty)
    }
}
