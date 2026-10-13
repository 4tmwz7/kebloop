import AppKit
import KebloopCore
import XCTest
@testable import Kebloop

@MainActor final class HistoryBrowsingTests: XCTestCase {
    func testHistoryShowsDistinctAcceptedEventsFiltersAndOffersClearAction() throws {
        _ = NSApplication.shared
        let suite = "HistoryBrowsing.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "clipboardHistoryEnabled")
        let board = NSPasteboard(name: .init(suite)); defer { board.releaseGlobally() }
        let history = CalculationHistoryStore(defaults: defaults)
        let result = CalculationResult(expression: "2 + 2", display: "4", clipboard: "4")
        history.recordAccepted(result); history.recordAccepted(result)
        let launcher = LauncherPanelController(index: ApplicationIndex(), quicklinks: QuicklinkStore(defaults: defaults), clipboard: ClipboardHistoryStore(defaults: defaults, pasteboard: board, storageURL: nil), aliases: AppAliasStore(defaults: defaults), ai: AIHandoffService(defaults: defaults, pasteboard: board), personalization: PersonalizationStore(defaults: defaults), currencyRates: CurrencyRateStore(defaults: defaults), calculationHistory: history)
        defer { launcher.dismiss(restoreFocus: false) }
        launcher.executeCommand(id: LauncherCommand.calculationHistory.id)
        XCTAssertEqual(launcher.resultIdentifiers, history.entries.map { "calculation-history:" + $0.id })
        XCTAssertEqual(Set(launcher.resultIdentifiers).count, 2)
        launcher.setQuery("2 +")
        XCTAssertEqual(launcher.resultIdentifiers.count, 2)
        launcher.showActions()
        XCTAssertEqual(launcher.visibleActionIdentifiers, [.open, .clearCalculationHistory])
        launcher.dismiss(restoreFocus: false)
        launcher.executeCommand(id: LauncherCommand.calculationHistory.id)
        launcher.setQuery("not saved")
        XCTAssertTrue(launcher.resultIdentifiers.isEmpty)
        XCTAssertEqual(history.entries.count, 2, "Browsing and typing do not add accepted calculations")
    }
}
