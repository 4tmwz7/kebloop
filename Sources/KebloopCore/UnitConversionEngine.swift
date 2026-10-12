import Foundation

enum SpecializedCalculation {
    case notHandled
    case incomplete
    case result(String)
    case failure(String)
}

struct UnitConversionEngine {
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    func evaluate(_ input: String) -> SpecializedCalculation {
        let separators = matches(of: #"(?i)\s+(to|in|as)(?=\s|$)"#, in: input)
        guard !separators.isEmpty else { return .notHandled }

        for match in separators.reversed() {
            guard let sourceRange = Range(match.range, in: input) else { continue }
            let prefix = String(input[..<sourceRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let source = parseQuantity(prefix) else { continue }

            let targetText = String(input[sourceRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if targetText.isEmpty { return .incomplete }

            guard let sourceUnit = unit(named: source.unit) else {
                return .failure("Unknown unit “\(source.unit)”.")
            }
            guard let targetUnit = unit(named: targetText) else {
                return .failure("Unknown unit “\(targetText)”.")
            }
            guard sourceUnit.dimension == targetUnit.dimension else {
                return .failure("Those units measure different things.")
            }

            let baseValue = source.value * sourceUnit.scale + sourceUnit.offset
            guard baseValue.isFinite else {
                return .failure("The converted value is outside the supported range.")
            }
            if sourceUnit.dimension == .temperature, baseValue < -0.0000001 {
                return .failure("That temperature is below absolute zero.")
            }
            let value = (baseValue - targetUnit.offset) / targetUnit.scale
            guard value.isFinite else {
                return .failure("The converted value is outside the supported range.")
            }
            return .result("\(format(value, locale: locale)) \(targetUnit.symbol)")
        }

        return .notHandled
    }

    private func parseQuantity(_ text: String) -> (value: Double, unit: String)? {
        guard let match = firstMatch(of: #"^\s*([+-]?(?:[0-9]+(?:[.,][0-9]*)?|[.,][0-9]+)(?:[eE][+-]?[0-9]+)?)\s*(.*?)\s*$"#, in: text),
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let literal = String(text[valueRange]).replacingOccurrences(of: ",", with: ".")
        let unit = String(text[unitRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, let value = Double(literal), value.isFinite else { return nil }
        return (value, unit)
    }

    private func unit(named rawName: String) -> UnitDefinition? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.replacingOccurrences(of: " ", with: "")

        // Data symbols are case-sensitive: b is a bit and B is a byte.
        if let dataUnit = Self.dataSymbols[compact] { return dataUnit }

        let normalized = Self.normalize(trimmed)
        if let dataUnit = Self.dataNames[normalized] { return dataUnit }
        return Self.units[normalized]
    }

    private func format(_ value: Double, locale: Locale) -> String {
        guard value != 0 else { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 12
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func matches(of pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func firstMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "º", with: "")
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let units: [String: UnitDefinition] = {
        var units: [String: UnitDefinition] = [:]

        func add(_ definition: UnitDefinition, aliases: [String]) {
            for alias in aliases { units[normalize(alias)] = definition }
        }

        let length = UnitDimension.length
        add(UnitDefinition(symbol: "m", dimension: length, scale: 1), aliases: ["m", "meter", "meters", "metre", "metres"])
        add(UnitDefinition(symbol: "km", dimension: length, scale: 1_000), aliases: ["km", "kilometer", "kilometers", "kilometre", "kilometres"])
        add(UnitDefinition(symbol: "cm", dimension: length, scale: 0.01), aliases: ["cm", "centimeter", "centimeters", "centimetre", "centimetres"])
        add(UnitDefinition(symbol: "mm", dimension: length, scale: 0.001), aliases: ["mm", "millimeter", "millimeters", "millimetre", "millimetres"])
        add(UnitDefinition(symbol: "µm", dimension: length, scale: 0.000001), aliases: ["um", "µm", "μm", "micrometer", "micrometers", "micrometre", "micrometres", "micron", "microns"])
        add(UnitDefinition(symbol: "nm", dimension: length, scale: 0.000000001), aliases: ["nm", "nanometer", "nanometers", "nanometre", "nanometres"])
        add(UnitDefinition(symbol: "mi", dimension: length, scale: 1_609.344), aliases: ["mi", "mile", "miles"])
        add(UnitDefinition(symbol: "yd", dimension: length, scale: 0.9144), aliases: ["yd", "yard", "yards"])
        add(UnitDefinition(symbol: "ft", dimension: length, scale: 0.3048), aliases: ["ft", "foot", "feet"])
        add(UnitDefinition(symbol: "in", dimension: length, scale: 0.0254), aliases: ["in", "inch", "inches"])

        let mass = UnitDimension.mass
        add(UnitDefinition(symbol: "g", dimension: mass, scale: 1), aliases: ["g", "gram", "grams"])
        add(UnitDefinition(symbol: "kg", dimension: mass, scale: 1_000), aliases: ["kg", "kilogram", "kilograms"])
        add(UnitDefinition(symbol: "mg", dimension: mass, scale: 0.001), aliases: ["mg", "milligram", "milligrams"])
        add(UnitDefinition(symbol: "µg", dimension: mass, scale: 0.000001), aliases: ["ug", "µg", "μg", "mcg", "microgram", "micrograms"])
        add(UnitDefinition(symbol: "lb", dimension: mass, scale: 453.59237), aliases: ["lb", "lbs", "pound", "pounds"])
        add(UnitDefinition(symbol: "oz", dimension: mass, scale: 28.349523125), aliases: ["oz", "ounce", "ounces"])
        add(UnitDefinition(symbol: "st", dimension: mass, scale: 6_350.29318), aliases: ["st", "stone", "stones"])

        let temperature = UnitDimension.temperature
        add(UnitDefinition(symbol: "°C", dimension: temperature, scale: 1, offset: 273.15), aliases: ["c", "°c", "ºc", "celsius", "centigrade", "degree c", "degrees c", "degree celsius", "degrees celsius"])
        add(UnitDefinition(symbol: "°F", dimension: temperature, scale: 5 / 9, offset: 255.3722222222222), aliases: ["f", "°f", "ºf", "fahrenheit", "degree f", "degrees f", "degree fahrenheit", "degrees fahrenheit"])
        add(UnitDefinition(symbol: "K", dimension: temperature, scale: 1), aliases: ["k", "kelvin", "kelvins", "degree k", "degrees k"])

        return units
    }()

    private static let dataSymbols: [String: UnitDefinition] = {
        var units: [String: UnitDefinition] = [:]
        let data = UnitDimension.data
        func add(_ symbol: String, _ factor: Double) { units[symbol] = UnitDefinition(symbol: symbol, dimension: data, scale: factor) }
        add("b", 1 / 8)
        add("B", 1)
        add("kb", 1_000 / 8)
        add("kB", 1_000)
        add("Mb", 1_000_000 / 8)
        add("MB", 1_000_000)
        add("Gb", 1_000_000_000 / 8)
        add("GB", 1_000_000_000)
        add("Tb", 1_000_000_000_000 / 8)
        add("TB", 1_000_000_000_000)
        add("Kib", 1_024 / 8)
        add("KiB", 1_024)
        add("Mib", 1_048_576 / 8)
        add("MiB", 1_048_576)
        add("Gib", 1_073_741_824 / 8)
        add("GiB", 1_073_741_824)
        add("Tib", 1_099_511_627_776 / 8)
        add("TiB", 1_099_511_627_776)
        return units
    }()

    private static let dataNames: [String: UnitDefinition] = {
        var names: [String: UnitDefinition] = [:]
        func add(_ symbol: String, _ factor: Double, _ aliases: [String]) {
            let definition = UnitDefinition(symbol: symbol, dimension: .data, scale: factor)
            for alias in aliases { names[normalize(alias)] = definition }
        }
        add("B", 1, ["byte", "bytes"])
        add("kB", 1_000, ["kilobyte", "kilobytes"])
        add("MB", 1_000_000, ["megabyte", "megabytes"])
        add("GB", 1_000_000_000, ["gigabyte", "gigabytes"])
        add("TB", 1_000_000_000_000, ["terabyte", "terabytes"])
        add("KiB", 1_024, ["kibibyte", "kibibytes"])
        add("MiB", 1_048_576, ["mebibyte", "mebibytes"])
        add("GiB", 1_073_741_824, ["gibibyte", "gibibytes"])
        add("TiB", 1_099_511_627_776, ["tebibyte", "tebibytes"])
        add("b", 1 / 8, ["bit", "bits"])
        add("kb", 1_000 / 8, ["kilobit", "kilobits"])
        add("Mb", 1_000_000 / 8, ["megabit", "megabits"])
        add("Gb", 1_000_000_000 / 8, ["gigabit", "gigabits"])
        add("Tb", 1_000_000_000_000 / 8, ["terabit", "terabits"])
        add("Kib", 1_024 / 8, ["kibibit", "kibibits"])
        add("Mib", 1_048_576 / 8, ["mebibit", "mebibits"])
        add("Gib", 1_073_741_824 / 8, ["gibibit", "gibibits"])
        add("Tib", 1_099_511_627_776 / 8, ["tebibit", "tebibits"])
        return names
    }()
}

private enum UnitDimension: Equatable {
    case length
    case mass
    case temperature
    case data
}

private struct UnitDefinition {
    let symbol: String
    let dimension: UnitDimension
    let scale: Double
    var offset: Double = 0
}
