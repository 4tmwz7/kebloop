import Foundation

public enum CalculationOutcome {
    case none
    case incomplete
    case result(CalculationResult)
    case failure(String)
}

public struct CalculationResult: Equatable, Sendable {
    public let expression: String
    public let display: String
    public let clipboard: String

    public init(expression: String, display: String, clipboard: String) {
        self.expression = expression
        self.display = display
        self.clipboard = clipboard
    }
}

/// Evaluates the small, self-contained calculator language used by the launcher.
public struct CalculatorEngine {
    private static let maximumInputLength = 512
    private static let maximumTokenCount = 256

    private let locale: Locale
    private let timeZone: TimeZone
    private let referenceDate: Date?

    public init(locale: Locale = .current, timeZone: TimeZone = .current, referenceDate: Date? = nil) {
        self.locale = locale
        self.timeZone = timeZone
        self.referenceDate = referenceDate
    }

    public func evaluate(_ input: String, currencyRates: [CurrencyRateSnapshot] = []) -> CalculationOutcome {
        let expression = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return .none }

        if expression.count > Self.maximumInputLength {
            return .failure("Expression is too long.")
        }

        let dateCalculator = DateCalculationEngine(locale: locale, timeZone: timeZone)
        switch dateCalculator.evaluate(expression, now: referenceDate ?? Date()) {
        case .notHandled:
            break
        case .incomplete:
            return .incomplete
        case .result(let display):
            return .result(CalculationResult(expression: expression, display: display, clipboard: display))
        case .resultWithClipboard(let display, let clipboard):
            return .result(CalculationResult(expression: expression, display: display, clipboard: clipboard))
        case .failure(let message):
            return .failure(message)
        }

        let timeZoneCalculator = TimeZoneCalculationEngine(locale: locale)
        switch timeZoneCalculator.evaluate(expression, now: referenceDate ?? Date()) {
        case .notHandled:
            break
        case .incomplete:
            return .incomplete
        case .result(let display):
            return .result(CalculationResult(expression: expression, display: display, clipboard: display))
        case .resultWithClipboard(let display, let clipboard):
            return .result(CalculationResult(expression: expression, display: display, clipboard: clipboard))
        case .failure(let message):
            return .failure(message)
        }

        let currencyCalculator = CurrencyConversionEngine(locale: locale)
        switch currencyCalculator.evaluate(expression, rates: currencyRates, now: referenceDate ?? Date()) {
        case .notHandled:
            break
        case .incomplete:
            return .incomplete
        case .result(let display):
            return .result(CalculationResult(expression: expression, display: display, clipboard: display))
        case .resultWithClipboard(let display, let clipboard):
            return .result(CalculationResult(expression: expression, display: display, clipboard: clipboard))
        case .failure(let message):
            return .failure(message)
        }

        let conversionCalculator = UnitConversionEngine(locale: locale)
        switch conversionCalculator.evaluate(expression) {
        case .notHandled:
            break
        case .incomplete:
            return .incomplete
        case .result(let display):
            return .result(CalculationResult(expression: expression, display: display, clipboard: display))
        case .resultWithClipboard(let display, let clipboard):
            return .result(CalculationResult(expression: expression, display: display, clipboard: clipboard))
        case .failure(let message):
            return .failure(message)
        }

        guard Self.looksLikeMath(expression) else { return .none }

        do {
            var parser = try Parser(source: expression, maximumTokenCount: Self.maximumTokenCount)
            let value = try parser.evaluate()
            let display = Self.format(value)
            return .result(CalculationResult(expression: expression, display: display, clipboard: display))
        } catch ParseIssue.incomplete {
            return .incomplete
        } catch ParseIssue.failure(let message) {
            return .failure(message)
        } catch {
            return .failure("Could not evaluate this expression.")
        }
    }

    /// Returns the currency pair in a conversion query, allowing the UI to refresh rates
    /// asynchronously without doing any network work in the typing path.
    public static func currencyPair(in input: String) -> CurrencyPair? {
        CurrencyConversionEngine.pair(in: input)
    }

    private static func looksLikeMath(_ input: String) -> Bool {
        let names = input.lowercased().split(whereSeparator: { !$0.isLetter })
        let knownNames: Set<String> = ["pi", "e", "sqrt", "abs", "round", "of", "off"]
        let hasUnknownName = names.contains { !knownNames.contains(String($0)) }
        let hasKnownName = names.contains { knownNames.contains(String($0)) }
        let hasNumber = input.contains(where: \.isNumber)

        if !hasUnknownName {
            return hasNumber || hasKnownName || input.contains(where: { "+-*/^%=().,".contains($0) })
        }

        // Search queries often contain digits and punctuation (for example, “1Password” or
        // “Visual Studio Code.app”). Treat mixed text as a calculation only when it also has
        // calculator syntax and a number or a recognized calculator name.
        let hasOperator = input.contains(where: { "+-*/^%×÷−".contains($0) })
        let hasParenthesis = input.contains(where: { "()".contains($0) })
        return (hasOperator || hasParenthesis) && (hasNumber || hasKnownName)
    }

    private static func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.16g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private enum ParseIssue: Error {
    case incomplete
    case failure(String)
}

private enum Token {
    case number(Double)
    case identifier(String)
    case plus
    case minus
    case multiply
    case divide
    case power
    case percent
    case leftParen
    case rightParen
    case end
}

private struct EvaluatedValue {
    var value: Double
    /// Retained only for a direct percentage value, so percentage phrases can use it.
    var isPercentage: Bool = false
}

private struct Parser {
    private let tokens: [Token]
    private var index = 0
    private var nestingDepth = 0

    init(source: String, maximumTokenCount: Int) throws {
        tokens = try Self.tokenize(source, maximumTokenCount: maximumTokenCount)
    }

    mutating func evaluate() throws -> Double {
        let result = try parseExpression()
        switch current {
        case .end:
            return result.value
        case .rightParen:
            throw ParseIssue.failure("There is an unmatched closing parenthesis.")
        case .identifier(let name):
            throw ParseIssue.failure("Unexpected “\(name)” after the expression.")
        default:
            throw ParseIssue.failure("There is unexpected content after the expression.")
        }
    }

    private var current: Token { tokens[index] }

    private mutating func advance() {
        if index < tokens.count - 1 { index += 1 }
    }

    private mutating func parseExpression() throws -> EvaluatedValue {
        var lhs = try parseTerm()
        while true {
            let operation: Token
            switch current {
            case .plus, .minus:
                operation = current
            default:
                return lhs
            }

            advance()
            let rhs = try parseTerm()
            switch operation {
            case .plus:
                lhs.value += rhs.value
            case .minus:
                lhs.value -= rhs.value
            default:
                break
            }
            lhs.isPercentage = false
            try Self.requireFinite(lhs.value)
        }
    }

    private mutating func parseTerm() throws -> EvaluatedValue {
        var lhs = try parseUnary()
        while true {
            switch current {
            case .multiply:
                advance()
                let rhs = try parseUnary()
                lhs = EvaluatedValue(value: lhs.value * rhs.value)
            case .divide:
                advance()
                let rhs = try parseUnary()
                guard rhs.value != 0 else { throw ParseIssue.failure("Cannot divide by zero.") }
                lhs = EvaluatedValue(value: lhs.value / rhs.value)
            case .identifier("of"):
                guard lhs.isPercentage else {
                    throw ParseIssue.failure("Use a percentage before “of”.")
                }
                advance()
                let rhs = try parseUnary()
                lhs = EvaluatedValue(value: lhs.value * rhs.value)
            case .identifier("off"):
                guard lhs.isPercentage else {
                    throw ParseIssue.failure("Use a percentage before “off”.")
                }
                advance()
                let base = try parseUnary()
                lhs = EvaluatedValue(value: base.value * (1 - lhs.value))
            default:
                try Self.requireFinite(lhs.value)
                return lhs
            }
            lhs.isPercentage = false
            try Self.requireFinite(lhs.value)
        }
    }

    /// Unary signs bind less tightly than exponentiation, while the exponent may itself be signed.
    private mutating func parseUnary() throws -> EvaluatedValue {
        switch current {
        case .plus:
            advance()
            return try parseUnary()
        case .minus:
            advance()
            var value = try parseUnary()
            value.value = -value.value
            try Self.requireFinite(value.value)
            return value
        default:
            return try parsePower()
        }
    }

    /// Recursing through the right operand makes exponentiation right-associative.
    private mutating func parsePower() throws -> EvaluatedValue {
        let base = try parsePostfix()
        guard case .power = current else { return base }
        advance()
        let exponent = try parseUnary()
        let value = Foundation.pow(base.value, exponent.value)
        try Self.requireFinite(value)
        return EvaluatedValue(value: value)
    }

    private mutating func parsePostfix() throws -> EvaluatedValue {
        var value = try parsePrimary()
        while case .percent = current {
            advance()
            value.value /= 100
            value.isPercentage = true
        }
        try Self.requireFinite(value.value)
        return value
    }

    private mutating func parsePrimary() throws -> EvaluatedValue {
        switch current {
        case .number(let value):
            advance()
            return EvaluatedValue(value: value)
        case .leftParen:
            try enterNestedExpression()
            advance()
            let value = try parseExpression()
            try consumeClosingParenthesis()
            leaveNestedExpression()
            return value
        case .identifier(let name):
            advance()
            switch name {
            case "pi": return EvaluatedValue(value: Double.pi)
            case "e": return EvaluatedValue(value: Foundation.exp(1))
            case "sqrt", "abs", "round":
                guard case .leftParen = current else {
                    if case .end = current { throw ParseIssue.incomplete }
                    throw ParseIssue.failure("Write “\(name)” with parentheses, such as \(name)(2).")
                }
                try enterNestedExpression()
                advance()
                let argument = try parseExpression().value
                try consumeClosingParenthesis()
                leaveNestedExpression()
                let result: Double
                switch name {
                case "sqrt":
                    guard argument >= 0 else { throw ParseIssue.failure("Square root needs a non-negative value.") }
                    result = Foundation.sqrt(argument)
                case "abs":
                    result = Swift.abs(argument)
                default:
                    result = argument.rounded(.toNearestOrAwayFromZero)
                }
                try Self.requireFinite(result)
                return EvaluatedValue(value: result)
            default:
                throw ParseIssue.failure("Unknown name “\(name)”.")
            }
        case .end:
            throw ParseIssue.incomplete
        case .rightParen:
            throw ParseIssue.incomplete
        default:
            throw ParseIssue.failure("Expected a number or a parenthesized expression.")
        }
    }

    private mutating func enterNestedExpression() throws {
        nestingDepth += 1
        guard nestingDepth <= 64 else { throw ParseIssue.failure("Expression is nested too deeply.") }
    }

    private mutating func consumeClosingParenthesis() throws {
        guard case .rightParen = current else {
            if case .end = current { throw ParseIssue.incomplete }
            throw ParseIssue.failure("Expected a closing parenthesis.")
        }
        advance()
    }

    private mutating func leaveNestedExpression() {
        nestingDepth -= 1
    }

    private static func requireFinite(_ value: Double) throws {
        guard value.isFinite else {
            throw ParseIssue.failure("The result is outside the supported numeric range.")
        }
    }

    private static func tokenize(_ source: String, maximumTokenCount: Int) throws -> [Token] {
        let characters = Array(source.lowercased())
        var output: [Token] = []
        var cursor = 0

        func append(_ token: Token) throws {
            guard output.count < maximumTokenCount else {
                throw ParseIssue.failure("Expression has too many parts.")
            }
            output.append(token)
        }

        while cursor < characters.count {
            let character = characters[cursor]
            if character.isWhitespace {
                cursor += 1
                continue
            }

            if character.isNumber || character == "." || character == "," {
                let start = cursor
                var separatorSeen = false
                var digitSeen = false

                while cursor < characters.count {
                    let next = characters[cursor]
                    if next.isNumber {
                        digitSeen = true
                        cursor += 1
                    } else if (next == "." || next == ",") && !separatorSeen {
                        separatorSeen = true
                        cursor += 1
                    } else {
                        break
                    }
                }
                guard digitSeen else { throw ParseIssue.failure("Expected digits in the number.") }

                if cursor < characters.count, characters[cursor] == "e" {
                    cursor += 1
                    if cursor < characters.count, characters[cursor] == "+" || characters[cursor] == "-" {
                        cursor += 1
                    }
                    let exponentStart = cursor
                    while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
                    guard cursor > exponentStart else { throw ParseIssue.incomplete }
                }

                let literal = String(characters[start..<cursor]).replacingOccurrences(of: ",", with: ".")
                guard let number = Double(literal), number.isFinite else {
                    throw ParseIssue.failure("That number is outside the supported range.")
                }
                try append(.number(number))
                continue
            }

            if character.isLetter {
                let start = cursor
                while cursor < characters.count, characters[cursor].isLetter { cursor += 1 }
                try append(.identifier(String(characters[start..<cursor])))
                continue
            }

            let token: Token
            switch character {
            case "+": token = .plus
            case "-", "−": token = .minus
            case "*", "×": token = .multiply
            case "/", "÷": token = .divide
            case "^": token = .power
            case "%": token = .percent
            case "(": token = .leftParen
            case ")": token = .rightParen
            default: throw ParseIssue.failure("Unsupported character “\(character)”.")
            }
            try append(token)
            cursor += 1
        }

        output.append(.end)
        return output
    }
}
