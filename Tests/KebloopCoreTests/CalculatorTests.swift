import XCTest
@testable import KebloopCore

final class CalculatorTests: XCTestCase {
    private let calculator = CalculatorEngine(locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)

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

    func testUnitConversionsCoverAliasesDimensionsAndTemperatureOffsets() throws {
        XCTAssertEqual(try result(for: "1 kilometer to miles"), "0.621371192237 mi")
        XCTAssertEqual(try result(for: "12 in to centimeters"), "30.48 cm")
        XCTAssertEqual(try result(for: "2 pounds to kg"), "0.90718474 kg")
        XCTAssertEqual(try result(for: "5 kilometers in miles"), "3.10685596119 mi")
        XCTAssertEqual(try result(for: "32 °F to °C"), "0 °C")
        XCTAssertEqual(try result(for: "0 celsius to fahrenheit"), "32 °F")
        XCTAssertEqual(try result(for: "1 MB to MiB"), "0.953674316406 MiB")
        XCTAssertEqual(try result(for: "1 MiB to bytes"), "1048576 B")
        XCTAssertEqual(try result(for: "1 MB as MiB"), "0.953674316406 MiB")
        XCTAssertEqual(try result(for: "8 bits to bytes"), "1 B")
        XCTAssertEqual(try result(for: "1 byte to bits"), "8 b")

        guard case .failure = calculator.evaluate("1 meter to kilograms") else {
            return XCTFail("Incompatible unit dimensions should fail")
        }
        guard case .failure = calculator.evaluate("1 fathom to meters") else {
            return XCTFail("Unknown units should fail")
        }
        guard case .failure = calculator.evaluate("-300 C to K") else {
            return XCTFail("Temperatures below absolute zero should fail")
        }
    }

    func testCurrencyConversionsUseCachedRatesAndShowTheirObservationDate() throws {
        let now = date("2026-10-13T12:00:00Z")
        let observation = date("2026-10-12T00:00:00Z")
        let pair = CurrencyPair(base: "USD", quote: "EUR")!
        let currentRate = CurrencyRateSnapshot(pair: pair, rate: 0.92, rateDate: observation, fetchedAt: now)
        let calculator = CalculatorEngine(locale: Locale(identifier: "en_US"), timeZone: timeZone("UTC"), referenceDate: now)

        guard case .result(let calculation) = calculator.evaluate("$100 to EUR", currencyRates: [currentRate]) else {
            return XCTFail("Expected a currency conversion from a cached rate")
        }
        XCTAssertEqual(calculation.display, "92.00 EUR (rate dated Oct 12, 2026)")
        XCTAssertEqual(calculation.clipboard, "92.00 EUR")
        XCTAssertEqual(CalculatorEngine.currencyPair(in: "100 USD in euros"), pair)
        XCTAssertNil(CalculatorEngine.currencyPair(in: "search for USD"))

        let staleRate = CurrencyRateSnapshot(pair: pair, rate: 0.92, rateDate: observation, fetchedAt: now.addingTimeInterval(-25 * 60 * 60))
        guard case .result(let staleResult) = calculator.evaluate("100 USD to EUR", currencyRates: [staleRate]) else {
            return XCTFail("A saved rate should still be usable offline")
        }
        XCTAssertTrue(staleResult.display.contains("cached"))

        guard case .failure(let message) = calculator.evaluate("100 USD to EUR") else {
            return XCTFail("A missing pair should report that a rate is unavailable")
        }
        XCTAssertTrue(message.contains("No saved exchange rate"))
        XCTAssertEqual(try result(for: "10 GBP to GBP"), "10.00 GBP")
    }

    func testDurationConversionsAndMixedUnitArithmetic() throws {
        XCTAssertEqual(try result(for: "90 minutes to hours"), "1.5 h")
        XCTAssertEqual(try result(for: "2 weeks in seconds"), "1209600 s")
        XCTAssertEqual(try result(for: "2 km + 300 m"), "2.3 km")
        XCTAssertEqual(try result(for: "2 m + 30 cm to cm"), "230 cm")
        XCTAssertEqual(try result(for: "1 hour + 30 minutes"), "1.5 h")
        XCTAssertEqual(try result(for: "3 ft - 4 in"), "2.66666666667 ft")

        guard case .failure = calculator.evaluate("2 m + 3 seconds") else {
            return XCTFail("Mixed dimensions should not be added")
        }
        guard case .failure = calculator.evaluate("20 °C + 5 °F") else {
            return XCTFail("Absolute temperatures should not be added")
        }
    }

    func testNamedTimeZoneLookupsAndConversionsUseCurrentDateRules() throws {
        let now = date("2026-10-13T12:00:00Z")
        let calculator = CalculatorEngine(locale: Locale(identifier: "en_US"), timeZone: timeZone("UTC"), referenceDate: now)

        let tokyo = try result(for: "time in Tokyo", using: calculator)
        XCTAssertTrue(tokyo.contains("21:00"), tokyo)
        XCTAssertTrue(tokyo.contains("GMT+09:00"), tokyo)

        let london = try result(for: "9:30 AM in New York to London", using: calculator)
        XCTAssertTrue(london.contains("14:30"), london)
        XCTAssertTrue(london.contains("GMT+01:00"), london)

        let daylightSaving = try result(for: "9 AM PST to CET", using: calculator)
        XCTAssertTrue(daylightSaving.contains("18:00"), daylightSaving)
        XCTAssertTrue(daylightSaving.contains("GMT+02:00"), daylightSaving)

        guard case .incomplete = calculator.evaluate("time in") else {
            return XCTFail("An unfinished named-zone lookup should remain incomplete")
        }
        guard case .failure = calculator.evaluate("10:00 AM in Nowhere to London") else {
            return XCTFail("Unknown zones should report an error")
        }
    }

    func testEveryDocumentedUnitAliasIsRecognized() {
        let aliases: [(String, String)] = [
            ("m", "m"), ("meter", "m"), ("meters", "m"), ("metre", "m"), ("metres", "m"),
            ("km", "m"), ("kilometer", "m"), ("kilometers", "m"), ("kilometre", "m"), ("kilometres", "m"),
            ("cm", "m"), ("centimeter", "m"), ("centimeters", "m"), ("centimetre", "m"), ("centimetres", "m"),
            ("mm", "m"), ("millimeter", "m"), ("millimeters", "m"), ("millimetre", "m"), ("millimetres", "m"),
            ("µm", "m"), ("um", "m"), ("μm", "m"), ("micrometer", "m"), ("micrometers", "m"),
            ("micrometre", "m"), ("micrometres", "m"), ("micron", "m"), ("microns", "m"),
            ("nm", "m"), ("nanometer", "m"), ("nanometers", "m"), ("nanometre", "m"), ("nanometres", "m"),
            ("mi", "m"), ("mile", "m"), ("miles", "m"), ("yd", "m"), ("yard", "m"), ("yards", "m"),
            ("ft", "m"), ("foot", "m"), ("feet", "m"), ("in", "m"), ("inch", "m"), ("inches", "m"),
            ("g", "g"), ("gram", "g"), ("grams", "g"), ("kg", "g"), ("kilogram", "g"), ("kilograms", "g"),
            ("mg", "g"), ("milligram", "g"), ("milligrams", "g"), ("µg", "g"), ("μg", "g"),
            ("ug", "g"), ("mcg", "g"), ("microgram", "g"), ("micrograms", "g"),
            ("lb", "g"), ("lbs", "g"), ("pound", "g"), ("pounds", "g"),
            ("oz", "g"), ("ounce", "g"), ("ounces", "g"), ("st", "g"), ("stone", "g"), ("stones", "g"),
            ("C", "K"), ("°C", "K"), ("ºC", "K"), ("celsius", "K"), ("centigrade", "K"),
            ("degree C", "K"), ("degrees C", "K"), ("degree celsius", "K"), ("degrees celsius", "K"),
            ("F", "K"), ("°F", "K"), ("ºF", "K"), ("fahrenheit", "K"),
            ("degree F", "K"), ("degrees F", "K"), ("degree fahrenheit", "K"), ("degrees fahrenheit", "K"),
            ("K", "K"), ("kelvin", "K"), ("kelvins", "K"), ("degree K", "K"), ("degrees K", "K"),
            ("b", "B"), ("B", "B"), ("kb", "B"), ("kB", "B"), ("Mb", "B"), ("MB", "B"),
            ("Gb", "B"), ("GB", "B"), ("Tb", "B"), ("TB", "B"), ("Kib", "B"), ("KiB", "B"),
            ("Mib", "B"), ("MiB", "B"), ("Gib", "B"), ("GiB", "B"), ("Tib", "B"), ("TiB", "B"),
            ("bit", "B"), ("bits", "B"), ("byte", "B"), ("bytes", "B"),
            ("kilobit", "B"), ("kilobits", "B"), ("kilobyte", "B"), ("kilobytes", "B"),
            ("megabit", "B"), ("megabits", "B"), ("megabyte", "B"), ("megabytes", "B"),
            ("gigabit", "B"), ("gigabits", "B"), ("gigabyte", "B"), ("gigabytes", "B"),
            ("terabit", "B"), ("terabits", "B"), ("terabyte", "B"), ("terabytes", "B"),
            ("kibibit", "B"), ("kibibits", "B"), ("kibibyte", "B"), ("kibibytes", "B"),
            ("mebibit", "B"), ("mebibits", "B"), ("mebibyte", "B"), ("mebibytes", "B"),
            ("gibibit", "B"), ("gibibits", "B"), ("gibibyte", "B"), ("gibibytes", "B"),
            ("tebibit", "B"), ("tebibits", "B"), ("tebibyte", "B"), ("tebibytes", "B")
        ]

        for (alias, target) in aliases {
            guard case .result(let result) = calculator.evaluate("1 \(alias) to \(target)") else {
                XCTFail("Documented unit alias was not recognized: \(alias)")
                continue
            }
            XCTAssertTrue(result.display.hasSuffix(" \(target)"), "Unexpected target for unit alias \(alias): \(result.display)")
        }
    }

    func testConversionsAcceptDecimalCommaAndFormatForLocale() throws {
        let germanCalculator = CalculatorEngine(locale: Locale(identifier: "de_DE"))
        guard case .result(let result) = germanCalculator.evaluate("1,5 m to ft") else {
            return XCTFail("A decimal comma should be accepted")
        }
        XCTAssertEqual(result.display, "4,92125984252 ft")
        XCTAssertEqual(result.clipboard, result.display)
    }

    func testDateDifferencesAdditionsLocaleAmbiguityAndDaylightSaving() throws {
        XCTAssertEqual(try result(for: "days between 2026-03-07 and 2026-03-09"), "2 days")
        XCTAssertEqual(try result(for: "date difference between 2026-03-07 and 2026-03-09"), "2 days")
        XCTAssertEqual(try result(for: "2026-03-07 to 2026-03-09"), "2 days")
        XCTAssertEqual(try result(for: "days between 2026-03-09 and 2026-03-07"), "-2 days")
        XCTAssertEqual(try result(for: "2026-01-31 + 1 month"), "Feb 28, 2026")
        XCTAssertEqual(try result(for: "2026-01-01 + 1 week"), "Jan 8, 2026")
        XCTAssertEqual(try result(for: "2026-01-01 - 1 year"), "Jan 1, 2025")

        let usCalculator = CalculatorEngine(locale: Locale(identifier: "en_US"), timeZone: timeZone("UTC"))
        let ukCalculator = CalculatorEngine(locale: Locale(identifier: "en_GB"), timeZone: timeZone("UTC"))
        XCTAssertEqual(try result(for: "01/02/2026 + 1 day", using: usCalculator), "Jan 3, 2026")
        XCTAssertEqual(try result(for: "01/02/2026 + 1 day", using: ukCalculator), "2 Feb 2026")

        let newYork = timeZone("America/New_York")
        let calendar = Calendar(identifier: .gregorian)
        var localCalendar = calendar
        localCalendar.timeZone = newYork
        let referenceDate = localCalendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12))!
        let nyCalculator = CalculatorEngine(locale: Locale(identifier: "en_US"), timeZone: newYork, referenceDate: referenceDate)
        XCTAssertEqual(try result(for: "today + 10 days", using: nyCalculator), "Jan 25, 2026")
        XCTAssertEqual(try result(for: "in 3 weeks", using: nyCalculator), "Feb 5, 2026")
        XCTAssertEqual(try result(for: "3 days from today", using: nyCalculator), "Jan 18, 2026")
        let dayAfterDST = try result(for: "2026-03-07 12:00 + 1 day", using: nyCalculator)
        XCTAssertTrue(dayAfterDST.hasPrefix("Mar 8, 2026"))
        XCTAssertTrue(dayAfterDST.contains("12:00"))
        XCTAssertFalse(dayAfterDST.hasSuffix("AM") || dayAfterDST.hasSuffix("PM"))
        XCTAssertEqual(
            try result(for: "days between 2026-03-08T00:00:00-05:00 and 2026-03-09T00:00:00-04:00", using: nyCalculator),
            "1 day"
        )
        XCTAssertEqual(
            try result(for: "days between 2026-03-08T00:00:00Z and 2026-03-09T00:00:00Z", using: nyCalculator),
            "1 day"
        )
    }

    func testIncompleteConversionsAndDateExpressionsStayQuiet() {
        guard case .incomplete = calculator.evaluate("2 km to") else {
            return XCTFail("An unfinished conversion should remain incomplete")
        }
        guard case .incomplete = calculator.evaluate("2 m + 30 cm to") else {
            return XCTFail("An unfinished mixed-unit target should remain incomplete")
        }
        guard case .incomplete = calculator.evaluate("today +") else {
            return XCTFail("An unfinished date addition should remain incomplete")
        }
        guard case .incomplete = calculator.evaluate("days between 2026-10-12 and") else {
            return XCTFail("An unfinished date difference should remain incomplete")
        }
        guard case .incomplete = calculator.evaluate("2026-10-12 to") else {
            return XCTFail("An unfinished date range should remain incomplete")
        }
        guard case .none = calculator.evaluate("search for 2026") else {
            return XCTFail("Ordinary text with digits should stay a search")
        }
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
        try result(for: expression, using: calculator, file: file, line: line)
    }

    private func result(for expression: String, using calculator: CalculatorEngine, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard case .result(let result) = calculator.evaluate(expression) else {
            XCTFail("Expected a result for \(expression)", file: file, line: line)
            throw TestFailure.expectedResult
        }
        return result.display
    }

    private func timeZone(_ identifier: String) -> TimeZone {
        guard let zone = TimeZone(identifier: identifier) else {
            fatalError("Missing test time zone \(identifier)")
        }
        return zone
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { fatalError("Invalid test timestamp \(value)") }
        return date
    }
}

private enum TestFailure: Error {
    case expectedResult
}
