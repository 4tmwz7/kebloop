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
            return .result(format(parsed.date, includesTime: parsed.includesTime))
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

        if let match = firstMatch(of: #"(?i)^(.+?)\s+([+-])\s*([0-9]+(?:[.,][0-9]+)?)\s*(days?|weeks?|months?|years?)\s*$"#, in: text),
           let dateRange = Range(match.range(at: 1), in: text),
           let operationRange = Range(match.range(at: 2), in: text),
           let amountRange = Range(match.range(at: 3), in: text),
           let unitRange = Range(match.range(at: 4), in: text) {
            let dateText = String(text[dateRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isDateCandidate(dateText) else { return .notHandled }
            guard let parsed = parseDate(dateText, now: now) else {
                return .failure("Use a valid date, such as 2026-10-12.")
            }
            let literal = String(text[amountRange]).replacingOccurrences(of: ",", with: ".")
            let parts = literal.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts[1].allSatisfy({ $0 == "0" }) else {
                return .failure("Date additions need a whole number of days, weeks, months, or years.")
            }
            guard let amount = Int(parts[0]) else {
                return .failure("That date is outside the supported range.")
            }
            let amountValue = text[operationRange] == "-" ? -amount : amount
            let unit = String(text[unitRange]).lowercased().trimmingCharacters(in: .whitespaces)
            return add(amountValue, unit: unit, to: parsed.date, includesTime: parsed.includesTime)
        }

        if let match = firstMatch(of: #"(?i)^in\s+([0-9]+)\s+(days?|weeks?|months?|years?)\s*$"#, in: text),
           let amountRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text) {
            guard let amount = Int(text[amountRange]) else {
                return .failure("That date is outside the supported range.")
            }
            let unit = String(text[unitRange]).lowercased()
            return add(amount, unit: unit, to: calendar.startOfDay(for: now), includesTime: false)
        }

        if let match = firstMatch(of: #"(?i)^([0-9]+)\s+(days?|weeks?|months?|years?)\s+from\s+today\s*$"#, in: text),
           let amountRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text) {
            guard let amount = Int(text[amountRange]) else {
                return .failure("That date is outside the supported range.")
            }
            let unit = String(text[unitRange]).lowercased()
            return add(amount, unit: unit, to: calendar.startOfDay(for: now), includesTime: false)
        }

        if hasTrailingDateOperation(text), let operand = dateOperandBeforeTrailingOperation(text), isDateCandidate(operand) {
            return .incomplete
        }
        return .notHandled
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

    private func add(_ amount: Int, unit: String, to date: Date, includesTime: Bool) -> SpecializedCalculation {
        let component: Calendar.Component
        switch unit {
        case "day", "days": component = .day
        case "week", "weeks": component = .weekOfYear
        case "month", "months": component = .month
        default: component = .year
        }
        // Bound offsets before Foundation calendar arithmetic: extreme values can
        // silently wrap or return the input date instead of reporting an error.
        let maximumOffset: Int
        switch component {
        case .day: maximumOffset = 3_660_000
        case .weekOfYear: maximumOffset = 522_000
        case .month: maximumOffset = 119_988
        default: maximumOffset = 9_999
        }
        guard (-maximumOffset...maximumOffset).contains(amount), isSupported(date),
              let result = calendar.date(byAdding: component, value: amount, to: date),
              isSupported(result),
              amount == 0 || (amount > 0 ? result > date : result < date) else {
            return .failure("That date is outside the supported range.")
        }
        return .result(format(result, includesTime: includesTime))
    }

    private func isSupported(_ date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        let components = calendar.dateComponents([.era, .year], from: date)
        return components.era == 1 && (1...9_999).contains(components.year ?? 0)
    }

    private func parseDate(_ rawText: String, now: Date) -> ParsedDate? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text.lowercased() {
        case "now": return isSupported(now) ? ParsedDate(date: now, includesTime: true) : nil
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
            return ParsedDate(date: date, includesTime: true)
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
            return ParsedDate(date: date, includesTime: includesTime)
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

    private func format(_ date: Date, includesTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = includesTime ? .short : .none
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
}
