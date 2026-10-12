import XCTest
@testable import Kebloop

final class LocalizationTests: XCTestCase {
    func testPackagedPolishLookupAndLocalizedAliasesKeepEnglishSearchNames() throws {
        let path = try XCTUnwrap(Bundle.module.path(forResource: "pl", ofType: "lproj"))
        let polish = try XCTUnwrap(Bundle(path: path))
        for (key, translated) in [("Open Settings", "Otwórz ustawienia"), ("Clipboard History", "Historia schowka"), ("Remove Item", "Usuń element")] {
            XCTAssertEqual(polish.localizedString(forKey: key, value: key, table: nil), translated)
        }
        XCTAssertTrue(LauncherCommand.settings.aliases.contains("settings"))
        XCTAssertTrue(LauncherCommand.settings.aliases.contains("ustawienia"))
        XCTAssertTrue(LauncherCommand.clipboard.aliases.contains("clipboard"))
        XCTAssertTrue(LauncherCommand.clipboard.aliases.contains("schowek"))
    }

    func testEnglishAndPolishCatalogsHaveMatchingKeysAndRealTranslations() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let folder = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
            let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try catalog("en"), polish = try catalog("pl")
        XCTAssertEqual(Set(english.keys), Set(polish.keys))
        XCTAssertEqual(polish["Open Settings"], "Otwórz ustawienia")
        XCTAssertEqual(polish["Clipboard History"], "Historia schowka")
        XCTAssertGreaterThan(english.count, 290)
        for (key, value) in polish { XCTAssertFalse(value.isEmpty, "Empty translation for \(key)") }
    }
}
