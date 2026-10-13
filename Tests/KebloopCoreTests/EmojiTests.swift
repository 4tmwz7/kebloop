import XCTest
@testable import KebloopCore

final class EmojiTests: XCTestCase {
    func testCatalogHasUniqueSymbolsAndUsefulBreadth() {
        XCTAssertEqual(EmojiCatalog.entries.count, 3_963)
        XCTAssertEqual(Set(EmojiCatalog.entries.map(\.id)).count, EmojiCatalog.entries.count)
        XCTAssertTrue(Set(EmojiCatalog.entries.map(\.category)).isSuperset(of: ["Smileys", "Animals", "Food", "Symbols", "Flags"]))
    }

    func testUnicode18CatalogIncludesFullyQualifiedSequencesAndVariants() {
        XCTAssertEqual(EmojiCatalog.unicodeVersion, "18.0")

        let symbols = Set(EmojiCatalog.entries.map(\.symbol))
        XCTAssertTrue(symbols.contains("🫫")) // Emoji 18.0 cracking face
        XCTAssertTrue(symbols.contains("👩🏽‍⚕️")) // profession with skin tone
        XCTAssertTrue(symbols.contains("👨‍👩‍👧‍👦")) // family ZWJ sequence
        XCTAssertTrue(symbols.contains("🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}")) // Scotland flag
        XCTAssertTrue(symbols.contains("1️⃣")) // keycap
        XCTAssertFalse(symbols.contains("🏻")) // standalone modifiers are excluded
    }

    func testFullyQualifiedSymbolsHaveNoVariationSelectorOnlyDuplicates() {
        let symbols = EmojiCatalog.entries.map(\.symbol)
        let withoutPresentationSelectors = symbols.map { $0.replacingOccurrences(of: "\u{FE0F}", with: "") }

        XCTAssertEqual(Set(withoutPresentationSelectors).count, symbols.count)
        XCTAssertEqual(EmojiCatalog.entry(forSymbol: "☕")?.symbol, "☕")
        XCTAssertEqual(EmojiCatalog.entry(forSymbol: "❤️")?.symbol, "❤️")
    }

    func testUnicodeCategoriesMapIntoPickerSections() {
        XCTAssertEqual(EmojiCatalog.entry(forSymbol: "🐕")?.category, "Animals")
        XCTAssertEqual(EmojiCatalog.entry(forSymbol: "🌸")?.category, "Nature")
        XCTAssertEqual(EmojiCatalog.entry(forSymbol: "🚆")?.category, "Travel")
        XCTAssertEqual(EmojiCatalog.entry(forSymbol: "🗼")?.category, "Places")
        XCTAssertEqual(EmojiCatalog.entry(forSymbol: "🏳️‍🌈")?.category, "Flags")
        XCTAssertEqual(EmojiCatalog.entry(forSymbol: "🏴‍☠️")?.category, "Flags")
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
