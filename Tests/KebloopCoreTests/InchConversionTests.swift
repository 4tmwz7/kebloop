import XCTest
@testable import KebloopCore

final class InchConversionTests: XCTestCase {
    private let calculator = CalculatorEngine(locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)

    func testConversionsCanTargetInchesUsingSymbolsAndNames() {
        assertResult("1 cm to in", equals: "0.393700787402 in")
        assertResult("1 cm to inch", equals: "0.393700787402 in")
        assertResult("1 cm to inches", equals: "0.393700787402 in")
        assertResult("1 cm to inchs", equals: "0.393700787402 in")
        assertResult("1 m in inches", equals: "39.3700787402 in")
        assertResult("1 m in in", equals: "39.3700787402 in")
        assertResult("1 in to in", equals: "1 in")
    }

    func testInchesWorkAsSourceAndMixedArithmeticTarget() {
        assertResult("12 inches to cm", equals: "30.48 cm")
        assertResult("2 m + 30 cm to in", equals: "90.5511811024 in")
    }

    func testScientificNotationStillConvertsToInches() {
        assertResult("1e-2 m to in", equals: "0.393700787402 in")
        assertResult("1e-3 m to in", equals: "0.0393700787402 in")
        assertResult("1e-3 m + 1 cm to in", equals: "0.433070866142 in")
    }

    private func assertResult(
        _ expression: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .result(let result) = calculator.evaluate(expression) else {
            XCTFail("Expected a conversion result for \(expression)", file: file, line: line)
            return
        }
        XCTAssertEqual(result.display, expected, file: file, line: line)
    }
}
