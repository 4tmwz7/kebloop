import Foundation

struct TimeZoneCalculationEngine {
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    func evaluate(_ input: String, now: Date) -> SpecializedCalculation {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = firstMatch(of: #"(?i)^time\s+in\s*(.*?)\s*$"#, in: text),
           let zoneRange = Range(match.range(at: 1), in: text) {
            let zoneName = String(text[zoneRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !zoneName.isEmpty else { return .incomplete }
            guard let zone = timeZone(named: zoneName) else { return .failure("Unknown time zone “\(zoneName)”.") }
            return .result(format(now, in: zone))
        }

        guard let match = firstMatch(of: #"(?i)^\s*([0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)?)\s+(?:in\s+)?(.+?)\s+to\s+(.+?)\s*$"#, in: text),
              let timeRange = Range(match.range(at: 1), in: text),
              let sourceRange = Range(match.range(at: 2), in: text),
              let targetRange = Range(match.range(at: 3), in: text) else {
            if text.range(of: #"(?i)^time\s+in\s*$|^[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)?\s+(?:in\s+.+)?\s+to\s*$"#, options: .regularExpression) != nil {
                return .incomplete
            }
            return .notHandled
        }

        let timeText = String(text[timeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = String(text[sourceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetName = String(text[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare number followed by a unit is usually a unit conversion such as
        // “12 km to mi”. Require a clock marker before interpreting a zone pair.
        guard timeText.contains(":") || timeText.range(of: #"(?i)\b(?:am|pm)\b"#, options: .regularExpression) != nil else {
            return .notHandled
        }
        guard let sourceZone = timeZone(named: sourceName) else { return .failure("Unknown time zone “\(sourceName)”.") }
        guard let targetZone = timeZone(named: targetName) else { return .failure("Unknown time zone “\(targetName)”.") }
        guard let sourceDate = date(for: timeText, in: sourceZone, relativeTo: now) else {
            return .failure("Use a time such as “9:30 AM” or “17:30”.")
        }
        return .result(format(sourceDate, in: targetZone))
    }

    private func date(for rawTime: String, in zone: TimeZone, relativeTo now: Date) -> Date? {
        guard let match = firstMatch(of: #"(?i)^\s*([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)?\s*$"#, in: rawTime),
              let hourRange = Range(match.range(at: 1), in: rawTime) else { return nil }
        let hourText = String(rawTime[hourRange])
        let minuteText = match.range(at: 2).location == NSNotFound ? "0" : Range(match.range(at: 2), in: rawTime).map { String(rawTime[$0]) } ?? "0"
        guard let rawHour = Int(hourText), let minute = Int(minuteText), minute < 60 else { return nil }

        var hour = rawHour
        if match.range(at: 3).location != NSNotFound {
            guard (1...12).contains(rawHour),
                  let meridiemRange = Range(match.range(at: 3), in: rawTime) else { return nil }
            let meridiem = rawTime[meridiemRange].lowercased()
            hour = (rawHour % 12) + (meridiem == "pm" ? 12 : 0)
        } else if !(0...23).contains(rawHour) {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = zone
        let dateParts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = dateParts.year, let month = dateParts.month, let day = dateParts.day else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = zone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute else { return nil }
        return date
    }

    private func format(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let name = zone.localizedName(for: .generic, locale: locale) ?? zone.identifier
        let offset = zone.secondsFromGMT(for: date)
        let sign = offset >= 0 ? "+" : "−"
        let absoluteOffset = abs(offset)
        let hours = absoluteOffset / 3_600
        let minutes = (absoluteOffset % 3_600) / 60
        return "\(formatter.string(from: date)) (\(name), GMT\(sign)\(String(format: "%02d:%02d", hours, minutes)))"
    }

    private func timeZone(named rawName: String) -> TimeZone? {
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if let identifier = Self.aliases[normalized] { return TimeZone(identifier: identifier) }
        let identifier = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TimeZone.knownTimeZoneIdentifiers.contains(identifier) else { return nil }
        return TimeZone(identifier: identifier)
    }

    private func firstMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static let aliases: [String: String] = [
        "utc": "UTC", "gmt": "GMT", "zulu": "UTC",
        "london": "Europe/London", "uk": "Europe/London", "britain": "Europe/London", "bst": "Europe/London",
        "new york": "America/New_York", "new york city": "America/New_York", "nyc": "America/New_York", "eastern": "America/New_York", "et": "America/New_York", "est": "America/New_York", "edt": "America/New_York",
        "chicago": "America/Chicago", "central": "America/Chicago", "ct": "America/Chicago", "cst": "America/Chicago", "cdt": "America/Chicago",
        "denver": "America/Denver", "mountain": "America/Denver", "mt": "America/Denver", "mst": "America/Denver", "mdt": "America/Denver",
        "phoenix": "America/Phoenix",
        "los angeles": "America/Los_Angeles", "la": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "pacific": "America/Los_Angeles", "pt": "America/Los_Angeles", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles",
        "toronto": "America/Toronto", "vancouver": "America/Vancouver", "honolulu": "Pacific/Honolulu",
        "warsaw": "Europe/Warsaw", "poland": "Europe/Warsaw",
        "berlin": "Europe/Berlin", "paris": "Europe/Paris", "rome": "Europe/Rome", "madrid": "Europe/Madrid", "amsterdam": "Europe/Amsterdam", "zurich": "Europe/Zurich", "cet": "Europe/Paris", "cest": "Europe/Paris",
        "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "osaka": "Asia/Tokyo",
        "beijing": "Asia/Shanghai", "shanghai": "Asia/Shanghai", "china": "Asia/Shanghai", "hong kong": "Asia/Hong_Kong", "singapore": "Asia/Singapore",
        "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "kolkata": "Asia/Kolkata", "india": "Asia/Kolkata", "ist": "Asia/Kolkata",
        "dubai": "Asia/Dubai", "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne", "auckland": "Pacific/Auckland"
    ]
}
