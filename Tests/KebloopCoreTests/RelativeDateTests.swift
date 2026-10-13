import Foundation
import XCTest
@testable import KebloopCore

final class RelativeDateTests: XCTestCase {
    private func calculator(zone: String = "UTC") -> CalculatorEngine {
        let now = ISO8601DateFormatter().date(from: "2026-10-13T02:34:56Z")!
        return CalculatorEngine(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: zone)!, referenceDate: now)
    }

    func testStandaloneNowAndTodayRespectLocalDateAndTime() throws {
        let engine = calculator(zone: "America/New_York")
        let today = try result("  TODAY  ", engine: engine)
        XCTAssertEqual(today.display, "Oct 12, 2026")
        XCTAssertEqual(today.clipboard, today.display)
        let now = try result("now", engine: engine)
        XCTAssertTrue(now.display.hasPrefix("Oct 12, 2026"), now.display)
        XCTAssertTrue(now.display.contains("22:34"), now.display)
        XCTAssertFalse(now.display.hasSuffix("AM") || now.display.hasSuffix("PM"), now.display)
        XCTAssertEqual(now.clipboard, now.display)
        XCTAssertEqual(try result("now + 1 day", engine: engine).display, now.display.replacingOccurrences(of: "Oct 12, 2026", with: "Oct 13, 2026"))
        guard case .none = engine.evaluate("today notes") else { return XCTFail("Only exact relative keywords should be calculations") }
        guard case .incomplete = engine.evaluate("now +") else { return XCTFail("An unfinished now offset should stay incomplete") }
    }

    func testOverflowAndUnrepresentableDatesFailInsteadOfReturningToday() {
        let engine = calculator()
        let amounts = ["9223372036854775807", "9223372036854775808", "18446744073709551616", String(repeating: "9", count: 100), "3660001"]
        for amount in amounts {
            for expression in ["\(amount) days from today", "in \(amount) days", "today + \(amount) days", "today - \(amount) days"] {
                guard case .failure(let message) = engine.evaluate(expression) else {
                    XCTFail("Must reject an out-of-range date: \(expression)"); continue
                }
                XCTAssertTrue(message.contains("supported range"), message)
            }
        }
        for expression in ["9999 years from today", "119988 months from today", "522000 weeks from today", "today + 3650000 days", "9999-12-31 + 1 day", "0001-01-01 - 1 day"] {
            guard case .failure = engine.evaluate(expression) else { XCTFail("Must reject unsupported result: \(expression)"); continue }
        }
    }

    func testValidLargeOffsetsZeroAndIntegerDecimalsKeepWorking() throws {
        let engine = calculator()
        XCTAssertEqual(try result("0 days from today", engine: engine).display, "Oct 13, 2026")
        XCTAssertEqual(try result("3 days from today", engine: engine).display, "Oct 16, 2026")
        XCTAssertEqual(try result("today + 3.0 days", engine: engine).display, "Oct 16, 2026")
        XCTAssertEqual(try result("today - 3,0 days", engine: engine).display, "Oct 10, 2026")
        XCTAssertEqual(try result("1000000 days from today", engine: engine).display, try result("today + 1000000 days", engine: engine).display)
        XCTAssertNotEqual(try result("1000000 days from today", engine: engine).display, try result("today", engine: engine).display)
        guard case .failure = engine.evaluate("today + 1.5 days") else { return XCTFail("Fractional calendar days remain unsupported") }
    }

    private func result(_ expression: String, engine: CalculatorEngine) throws -> CalculationResult {
        guard case .result(let result) = engine.evaluate(expression) else {
            XCTFail("Expected a result for \(expression)")
            throw NSError(domain: "RelativeDateTests", code: 1)
        }
        return result
    }
}
