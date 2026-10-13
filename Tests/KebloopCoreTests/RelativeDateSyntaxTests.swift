import Foundation
import XCTest
@testable import KebloopCore

final class RelativeDateSyntaxTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testCompactAndSpacedUnitAliasesAreAccepted() throws {
        let engine = calculator()
        let aliases: [(String, String, String)] = [
            ("s", "sec", "second"), ("secs", "seconds", "second"),
            ("m", "min", "minute"), ("mins", "minutes", "minute"),
            ("h", "hr", "hour"), ("hrs", "hours", "hour"),
            ("d", "day", "day"), ("days", "day", "day"),
            ("w", "wk", "week"), ("wks", "weeks", "week"),
            ("mo", "mth", "month"), ("mos", "months", "month"),
            ("yr", "y", "year"), ("yrs", "years", "year")
        ]

        for (compactAlias, spacedAlias, canonical) in aliases {
            let base = DateOffsetBase.forUnit(canonical)
            let expected = try result("1 \(canonical) from \(base)", engine: engine)
            XCTAssertEqual(try result("1\(compactAlias) from \(base)", engine: engine), expected, compactAlias)
            XCTAssertEqual(try result("1 \(spacedAlias) from \(base)", engine: engine), expected, spacedAlias)
        }
    }

    func testRelativeFormsUseTheSelectedNowOrTodayBase() throws {
        let engine = calculator()
        XCTAssertEqual(try result("3days from now", engine: engine), try result("now + 3 d", engine: engine))
        XCTAssertEqual(try result("3d from now", engine: engine), try result("now + 3days", engine: engine))
        XCTAssertEqual(try result("3 day from today", engine: engine), try result("today + 3days", engine: engine))
        XCTAssertEqual(try result("in 2h", engine: engine), try result("now + 2 hours", engine: engine))
        XCTAssertEqual(try result("now-3d", engine: engine), "Oct 10, 2026 at 02:34:56")
        XCTAssertEqual(try result("today + 1d", engine: engine), "Oct 14, 2026")
        XCTAssertEqual(try result("-1 day from now", engine: engine), "Oct 12, 2026 at 02:34:56")
    }

    func testTodaySubdayOffsetsShowClockTimeAndSecondPrecision() throws {
        let engine = calculator()
        XCTAssertEqual(try result("today + 1h", engine: engine), "Oct 13, 2026 at 01:00")
        XCTAssertEqual(try result("today + 1min", engine: engine), "Oct 13, 2026 at 00:01")
        XCTAssertEqual(try result("today+1s", engine: engine), "Oct 13, 2026 at 00:00:01")
        XCTAssertEqual(try result("now", engine: engine), "Oct 13, 2026 at 02:34:56")
        XCTAssertEqual(try result("now + 1sec", engine: engine), "Oct 13, 2026 at 02:34:57")

        XCTAssertEqual(try result("2hours from today", engine: engine), "Oct 13, 2026 at 02:00")
        XCTAssertEqual(try result("today + 2 hours", engine: engine), "Oct 13, 2026 at 02:00")
        XCTAssertEqual(try result("30 minutes from today", engine: engine), "Oct 13, 2026 at 00:30")
        XCTAssertEqual(try result("today + 30min", engine: engine), "Oct 13, 2026 at 00:30")
        XCTAssertEqual(try result("45 seconds from today", engine: engine), "Oct 13, 2026 at 00:00:45")
        XCTAssertEqual(try result("today + 45s", engine: engine), "Oct 13, 2026 at 00:00:45")
    }

    func testFromNowCalendarOffsetsRetainLocalTimeAcrossBothDSTChanges() throws {
        XCTAssertEqual(
            try result("1 day from now", engine: calculator(zone: "America/New_York", local: (2026, 3, 7, 12, 0, 0))),
            "Mar 8, 2026 at 12:00:00"
        )
        XCTAssertEqual(
            try result("1 day from now", engine: calculator(zone: "America/New_York", local: (2026, 10, 31, 12, 0, 0))),
            "Nov 1, 2026 at 12:00:00"
        )
    }

    func testOverflowAndUnsupportedYearsFailForEveryRelativeForm() {
        let engine = calculator()
        for expression in [
            "9223372036854775808 days from now",
            "now + 9223372036854775808d",
            "in 999999999999999999999 seconds",
            "today + 315537897600 seconds",
            "9999-12-31 + 1d",
            "0001-01-01 - 1d"
        ] {
            guard case .failure(let message) = engine.evaluate(expression) else {
                XCTFail("Expected out-of-range input to fail: \(expression)")
                continue
            }
            XCTAssertTrue(message.contains("supported range"), message)
        }
    }

    func testFractionalOffsetsReportThatWholeAmountsAreRequired() {
        let engine = calculator()
        for expression in [
            "1.5 seconds from now",
            "today + 1.5 hours",
            "now + 1.5d",
            "in 1.5h"
        ] {
            guard case .failure(let message) = engine.evaluate(expression) else {
                XCTFail("Expected fractional date offset to fail: \(expression)")
                continue
            }
            XCTAssertTrue(message.contains("whole number"), message)
        }
    }

    func testDateRangesAndDurationConversionsStillReachTheirOwnCalculators() throws {
        let engine = calculator()
        XCTAssertEqual(try result("2026-10-12 to 2026-10-13", engine: engine), "1 day")
        XCTAssertEqual(try result("3 days to hours", engine: engine), "72 h")
    }

    private func calculator(zone: String = "UTC", local: (Int, Int, Int, Int, Int, Int)? = nil) -> CalculatorEngine {
        let timeZone = TimeZone(identifier: zone)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let referenceDate: Date
        if let local {
            referenceDate = calendar.date(from: DateComponents(year: local.0, month: local.1, day: local.2, hour: local.3, minute: local.4, second: local.5))!
        } else {
            referenceDate = ISO8601DateFormatter().date(from: "2026-10-13T02:34:56Z")!
        }
        return CalculatorEngine(locale: locale, timeZone: timeZone, referenceDate: referenceDate)
    }

    private func result(_ expression: String, engine: CalculatorEngine) throws -> String {
        guard case .result(let result) = engine.evaluate(expression) else {
            XCTFail("Expected a result for \(expression)")
            throw NSError(domain: "RelativeDateSyntaxTests", code: 1)
        }
        return result.display.replacingOccurrences(of: "\u{202F}", with: " ")
    }
}

private enum DateOffsetBase {
    static func forUnit(_ unit: String) -> String {
        ["second", "minute", "hour"].contains(unit) ? "now" : "today"
    }
}
