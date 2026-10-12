import XCTest
@testable import KebloopCore

final class CalculatorTests: XCTestCase {
    private let calculator = CalculatorEngine()

    func testOperatorPrecedenceAndAssociativity() throws {
        XCTAssertEqual(try result(for: "-2^2"), "-4")
        XCTAssertEqual(try result(for: "2^3^2"), "512")
        XCTAssertEqual(try result(for: "2^-2"), "0.25")
        XCTAssertEqual(try result(for: "(2 + 3) * 4"), "20")
    }

    func testDecimalSeparatorsScientificNotationAndConstants() throws {
        XCTAssertEqual(try result(for: "1,5 + 2.25 + 1e2"), "103.75")
        XCTAssertEqual(try result(for: "pi * 2"), "6.283185307179586")
        XCTAssertEqual(try result(for: "e"), "2.718281828459045")
    }

    func testFunctionsAndPercentageExpressions() throws {
        XCTAssertEqual(try result(for: "sqrt(81) + abs(-2)"), "11")
        XCTAssertEqual(try result(for: "round(2.6)"), "3")
        XCTAssertEqual(try result(for: "15% of 200"), "30")
        XCTAssertEqual(try result(for: "20% off 80"), "64")
        XCTAssertEqual(try result(for: "200 + 10%"), "200.1")
        XCTAssertEqual(try result(for: "80 - 20%"), "79.8")
        XCTAssertEqual(try result(for: "15%"), "0.15")
    }

    func testResultsAreUsefulForDisplayAndClipboard() throws {
        guard case .result(let calculation) = calculator.evaluate(" 0.1 + 0.2 ") else {
            return XCTFail("Expected a calculated result")
        }
        XCTAssertEqual(calculation.expression, "0.1 + 0.2")
        XCTAssertEqual(calculation.display, "0.3")
        XCTAssertEqual(calculation.clipboard, "0.3")
    }

    func testIncompleteAndNonMathInputsStayQuiet() {
        guard case .incomplete = calculator.evaluate("2 +") else {
            return XCTFail("An unfinished arithmetic expression should remain incomplete")
        }
        guard case .incomplete = calculator.evaluate("sqrt(") else {
            return XCTFail("An unfinished function call should remain incomplete")
        }
        guard case .incomplete = calculator.evaluate("1e") else {
            return XCTFail("An unfinished scientific notation exponent should remain incomplete")
        }
        guard case .none = calculator.evaluate("mail") else {
            return XCTFail("Ordinary search text should not become a calculator error")
        }
        for searchQuery in ["1Password", "Visual Studio Code.app", "PowerPoint 365"] {
            guard case .none = calculator.evaluate(searchQuery) else {
                XCTFail("App-like search text should not become a calculator error: \(searchQuery)")
                continue
            }
        }
    }

    func testInvalidExpressionsReportFailures() {
        for expression in ["2 / 0", "sqrt(-1)", "2 + * 3", "1..2", "unknown(2)"] {
            guard case .failure = calculator.evaluate(expression) else {
                XCTFail("Expected a failure for \(expression)")
                continue
            }
        }
    }

    func testInputAndParserLimitsRejectExcessiveWorkAndOverflow() {
        let tooLong = String(repeating: "9", count: 513)
        let tooManyTokens = String(repeating: "1+", count: 256)
        let tooDeep = String(repeating: "(", count: 65) + "1" + String(repeating: ")", count: 65)

        for expression in [tooLong, tooManyTokens, tooDeep, "1e309", "10^10000", "0^-1"] {
            guard case .failure = calculator.evaluate(expression) else {
                XCTFail("Expected a bounded failure for \(expression.prefix(40))")
                continue
            }
        }
    }

    private func result(for expression: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard case .result(let result) = calculator.evaluate(expression) else {
            XCTFail("Expected a result for \(expression)", file: file, line: line)
            throw TestFailure.expectedResult
        }
        return result.display
    }
}

private enum TestFailure: Error {
    case expectedResult
}
