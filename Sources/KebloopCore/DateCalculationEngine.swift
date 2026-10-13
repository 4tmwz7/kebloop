import Foundation

struct DateCalculationEngine {
    private let locale: Locale
    private let timeZone: TimeZone

    init(locale: Locale, timeZone: TimeZone) {
        self.locale = locale
        self.timeZone = timeZone
    }

    func evaluate(_ input: String, now: Date) -> SpecializedCalculation {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["now", "today"].contains(text.lowercased()), let parsed = parseDate(text, now: now) {
            return .result(format(parsed.date, includesTime: parsed.includesTime, includesSeconds: parsed.includesSeconds))
        }

        if let range = text.range(of: #"(?i)^date\s+difference\s+between\s+"#, options: .regularExpression) {
            return evaluateExplicitDifference(String(text[range.upperBound...]), now: now)
        }
        if let range = text.range(of: #"(?i)^days?\s+between\s+"#, options: .regularExpression) {
            return evaluateExplicitDifference(String(text[range.upperBound...]), now: now)
        }

        if let match = firstMatch(of: #"(?i)^(.+?)\s+to\s+(.+?)\s*$"#, in: text),
           let leftRange = Range(match.range(at: 1), in: text),
           let rightRange = Range(match.range(at: 2), in: text) {
            let left = String(text[leftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(text[rightRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isDateCandidate(left) { return difference(left, right, now: now) }
        }

        if startsWithDateDifferenceIntent(text) {
            return .incomplete
        }

        if let outcome = evaluateRelativeOffset(text, now: now) {
            return outcome
        }

        if let match = firstMatch(of: #"(?i)^(.+?)\s+([+-])\s*([0-9]+(?:[.,][0-9]+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wks?|w|wk|months?|mos?|mths?|mo|mth|years?|yrs?|yr|y)\s*$"#, in: text),
           let dateRange = Range(match.range(at: 1), in: text),
           let operationRange = Range(match.range(at: 2), in: text),
           let amountRange = Range(match.range(at: 3), in: text),
           let unitRange = Range(match.range(at: 4), in: text) {
            let dateText = String(text[dateRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isDateCandidate(dateText) else { return .notHandled }
            guard let parsed = parseDate(dateText, now: now) else {
                return .failure("Use a valid date, such as 2026-10-12.")
            }
            let literal = String(text[amountRange])
            guard let amount = parseWholeAmount(literal) else {
                return .failure(isWholeAmount(literal) ? "That date is outside the supported range." : "Date additions need a whole number of units.")
            }
            guard text[operationRange] != "-" || amount != Int.min else {
                return .failure("That date is outside the supported range.")
            }
            let amountValue = text[operationRange] == "-" ? -amount : amount
            guard let unit = DateOffsetUnit(rawValue: String(text[unitRange]).lowercased()) else { return .notHandled }
            return add(amountValue, unit: unit, to: parsed.date, includesTime: parsed.includesTime, includesSeconds: parsed.includesSeconds)
        }

        if hasTrailingDateOperation(text), let operand = dateOperandBeforeTrailingOperation(text), isDateCandidate(operand) {
            return .incomplete
        }
        return .notHandled
    }

    private func evaluateRelativeOffset(_ text: String, now: Date) -> SpecializedCalculation? {
        let unitPattern = #"(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wks?|w|wk|months?|mos?|mths?|mo|mth|years?|yrs?|yr|y)"#

        if let match = firstMatch(of: #"(?i)^(now|today)\s*([+-])\s*([0-9]+(?:[.,][0-9]+)?)\s*"# + unitPattern + #"\s*$"#, in: text),
           let baseRange = Range(match.range(at: 1), in: text),
           let operationRange = Range(match.range(at: 2), in: text),
           let amountRange = Range(match.range(at: 3), in: text),
           let unitRange = Range(match.range(at: 4), in: text) {
            let base = String(text[baseRange]).lowercased()
            let operation = String(text[operationRange])
            let literal = String(text[amountRange])
            guard let amount = parseWholeAmount(literal) else {
                return .failure(isWholeAmount(literal) ? "That date is outside the supported range." : "Date additions need a whole number of units.")
            }
            guard let unit = DateOffsetUnit(rawValue: String(text[unitRange]).lowercased()) else { return nil }
            guard let parsed = parseDate(base, now: now) else {
                return .failure("That date is outside the supported range.")
            }
            guard operation != "-" || amount != Int.min else {
                return .failure("That date is outside the supported range.")
            }
            let signedAmount = operation == "-" ? -amount : amount
            return add(signedAmount, unit: unit, to: parsed.date, includesTime: parsed.includesTime, includesSeconds: parsed.includesSeconds)
        }

        if let match = firstMatch(of: #"(?i)^([+-]?[0-9]+(?:[.,][0-9]+)?)\s*"# + unitPattern + #"\s+from\s+(now|today)\s*$"#, in: text),
           let amountRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text),
           let baseRange = Range(match.range(at: 3), in: text) {
            let literal = String(text[amountRange])
            guard let amount = parseWholeAmount(literal) else {
                return .failure(isWholeAmount(literal) ? "That date is outside the supported range." : "Date additions need a whole number of units.")
            }
            guard let unit = DateOffsetUnit(rawValue: String(text[unitRange]).lowercased()) else { return nil }
            let base = String(text[baseRange]).lowercased()
            guard let parsed = parseDate(base, now: now) else {
                return .failure("That date is outside the supported range.")
            }
            return add(amount, unit: unit, to: parsed.date, includesTime: parsed.includesTime, includesSeconds: parsed.includesSeconds)
        }

        if let match = firstMatch(of: #"(?i)^in\s+([+-]?[0-9]+(?:[.,][0-9]+)?)\s*"# + unitPattern + #"\s*$"#, in: text),
           let amountRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text) {
            let literal = String(text[amountRange])
            guard let amount = parseWholeAmount(literal) else {
                return .failure(isWholeAmount(literal) ? "That date is outside the supported range." : "Date additions need a whole number of units.")
            }
            guard let unit = DateOffsetUnit(rawValue: String(text[unitRange]).lowercased()) else { return nil }
            // Keep existing calendar-date behavior for `in 3 days`; short durations
            // naturally count forward from the current instant.
            let isDuration = unit.isDuration
            let base = isDuration ? now : calendar.startOfDay(for: now)
            return add(amount, unit: unit, to: base, includesTime: isDuration, includesSeconds: isDuration)
        }

        if text.range(of: #"(?i)^(?:now|today)\s*[+-]\s*$"#, options: .regularExpression) != nil {
            return .incomplete
        }
        return nil
    }

    private func parseWholeAmount(_ literal: String) -> Int? {
        let normalized = literal.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard isWholeAmount(literal) else { return nil }
        let integer = String(parts[0])
        if integer.hasPrefix("+") { return Int(integer.dropFirst()) }
        return Int(integer)
    }

    private func isWholeAmount(_ literal: String) -> Bool {
        let normalized = literal.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 1 || parts[1].allSatisfy({ $0 == "0" })
    }

    private func evaluateExplicitDifference(_ text: String, now: Date) -> SpecializedCalculation {
        guard let match = firstMatch(of: #"(?i)^(.+?)\s+and\s+(.+?)\s*$"#, in: text),
              let leftRange = Range(match.range(at: 1), in: text),
              let rightRange = Range(match.range(at: 2), in: text) else {
            return .incomplete
        }
        let left = String(text[leftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(text[rightRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return difference(left, right, now: now)
    }

    private func difference(_ left: String, _ right: String, now: Date) -> SpecializedCalculation {
        guard let first = parseDate(left, now: now), let second = parseDate(right, now: now) else {
            return .failure("Use valid dates, such as 2026-10-12.")
        }
        let firstDay = calendar.startOfDay(for: first.date)
        let secondDay = calendar.startOfDay(for: second.date)
        guard let days = calendar.dateComponents([.day], from: firstDay, to: secondDay).day else {
            return .failure("Could not calculate the date difference.")
        }
        return .result(days == 1 ? "1 day" : "\(days) days")
    }

    private func add(_ amount: Int, unit: DateOffsetUnit, to date: Date, includesTime: Bool, includesSeconds: Bool = false) -> SpecializedCalculation {
        guard isSupported(date) else { return .failure("That date is outside the supported range.") }

        let result: Date?
        switch unit {
        case .second, .minute, .hour:
            guard let secondsPerUnit = unit.secondsPerUnit else {
                return .failure("That date is outside the supported range.")
            }
            // Bound elapsed-time arithmetic to a wide interval around the supported
            // Gregorian range before constructing a TimeInterval.
            let maximumSeconds = 315_537_897_599.0
            guard abs(Double(amount) * secondsPerUnit) <= maximumSeconds else {
                return .failure("That date is outside the supported range.")
            }
            result = date.addingTimeInterval(Double(amount) * secondsPerUnit)
        case .day, .week, .month, .year:
            let component: Calendar.Component
            let maximumOffset: Int
            switch unit {
            case .day: component = .day; maximumOffset = 3_660_000
            case .week: component = .weekOfYear; maximumOffset = 522_000
            case .month: component = .month; maximumOffset = 119_988
            default: component = .year; maximumOffset = 9_999
            }
            guard (-maximumOffset...maximumOffset).contains(amount) else {
                return .failure("That date is outside the supported range.")
            }
            result = calendar.date(byAdding: component, value: amount, to: date)
        }

        guard let result, isSupported(result),
              amount == 0 || (amount > 0 ? result > date : result < date) else {
            return .failure("That date is outside the supported range.")
        }
        let showsTime = includesTime || unit.isDuration
        return .result(format(result, includesTime: showsTime, includesSeconds: includesSeconds || unit == .second))
    }

    private func isSupported(_ date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        let components = calendar.dateComponents([.era, .year], from: date)
        return components.era == 1 && (1...9_999).contains(components.year ?? 0)
    }

    private func parseDate(_ rawText: String, now: Date) -> ParsedDate? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text.lowercased() {
        case "now": return isSupported(now) ? ParsedDate(date: now, includesTime: true, includesSeconds: true) : nil
        case "today": return ParsedDate(date: calendar.startOfDay(for: now), includesTime: false)
        case "tomorrow":
            guard let date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
            return ParsedDate(date: date, includesTime: false)
        case "yesterday":
            guard let date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return nil }
            return ParsedDate(date: date, includesTime: false)
        default: break
        }

        if text.contains("T"), let date = parseOffsetTimestamp(text) {
            let includesSeconds = firstMatch(of: #"[0-9]{2}:[0-9]{2}:[0-9]{2}"#, in: text) != nil
            return ParsedDate(date: date, includesTime: true, includesSeconds: includesSeconds)
        }

        if let match = firstMatch(of: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[ T]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?)?$"#, in: text),
           let yearRange = Range(match.range(at: 1), in: text),
           let monthRange = Range(match.range(at: 2), in: text),
           let dayRange = Range(match.range(at: 3), in: text) {
            let year = Int(text[yearRange]) ?? 0
            let month = Int(text[monthRange]) ?? 0
            let day = Int(text[dayRange]) ?? 0
            let includesTime = match.range(at: 4).location != NSNotFound
            let hour = integer(in: text, range: match.range(at: 4)) ?? 0
            let minute = integer(in: text, range: match.range(at: 5)) ?? 0
            let second = integer(in: text, range: match.range(at: 6)) ?? 0
            guard let date = makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second) else { return nil }
            return ParsedDate(date: date, includesTime: includesTime, includesSeconds: match.range(at: 6).location != NSNotFound)
        }

        return parseLocalizedDate(text)
    }

    private func parseOffsetTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func parseLocalizedDate(_ text: String) -> ParsedDate? {
        // Use the user's locale for numeric date order. Four-digit years and the locale's
        // separators keep ambiguous day/month input deterministic.
        guard text.rangeOfCharacter(from: CharacterSet(charactersIn: "/.-")) != nil,
              let format = DateFormatter.dateFormat(fromTemplate: "Mdyyyy", options: 0, locale: locale) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.isLenient = false
        formatter.dateFormat = format
        guard let date = formatter.date(from: text) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year != nil, components.month != nil, components.day != nil else { return nil }
        return ParsedDate(date: calendar.startOfDay(for: date), includesTime: false)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second else { return nil }
        return date
    }

    private func integer(in text: String, range: NSRange) -> Int? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return Int(text[swiftRange])
    }

    private func isDateCandidate(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["now", "today", "tomorrow", "yesterday"].contains(value.lowercased()) { return true }
        return firstMatch(of: #"^(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}[./-][0-9]{1,2}[./-][0-9]{2,4})(?:$|[ T])"#, in: value) != nil
    }

    private func startsWithDateDifferenceIntent(_ text: String) -> Bool {
        text.range(of: #"(?i)^(?:date\s+difference\s+between|days?\s+between)\b"#, options: .regularExpression) != nil
    }

    private func hasTrailingDateOperation(_ text: String) -> Bool {
        text.range(of: #"(?i)(?:\s+to\s*|\s+[+-]\s*)$"#, options: .regularExpression) != nil
    }

    private func dateOperandBeforeTrailingOperation(_ text: String) -> String? {
        guard let match = firstMatch(of: #"(?i)^(.+?)\s+(?:to\s*|[+-]\s*)$"#, in: text),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func format(_ date: Date, includesTime: Bool, includesSeconds: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        let template = includesTime
            ? (includesSeconds ? "yMMMdHHmmss" : "yMMMdHHmm")
            : "yMMMd"
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = locale
        value.timeZone = timeZone
        return value
    }

    private func firstMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

private struct ParsedDate {
    let date: Date
    let includesTime: Bool
    let includesSeconds: Bool

    init(date: Date, includesTime: Bool, includesSeconds: Bool = false) {
        self.date = date
        self.includesTime = includesTime
        self.includesSeconds = includesSeconds
    }
}

private enum DateOffsetUnit: Equatable {
    case second, minute, hour, day, week, month, year

    init?(rawValue: String) {
        switch rawValue {
        case "second", "seconds", "sec", "secs", "s": self = .second
        case "minute", "minutes", "min", "mins", "m": self = .minute
        case "hour", "hours", "hr", "hrs", "h": self = .hour
        case "day", "days", "d": self = .day
        case "week", "weeks", "w", "wk", "wks": self = .week
        case "month", "months", "mo", "mos", "mth", "mths": self = .month
        case "year", "years", "y", "yr", "yrs": self = .year
        default: return nil
        }
    }

    var isDuration: Bool {
        switch self {
        case .second, .minute, .hour: return true
        case .day, .week, .month, .year: return false
        }
    }

    var secondsPerUnit: Double? {
        switch self {
        case .second: return 1
        case .minute: return 60
        case .hour: return 3_600
        case .day, .week, .month, .year: return nil
        }
    }
}
