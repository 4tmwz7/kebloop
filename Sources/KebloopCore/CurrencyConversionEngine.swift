import Foundation

public struct CurrencyPair: Codable, Hashable, Sendable {
    public let base: String
    public let quote: String

    public init?(base: String, quote: String) {
        let base = base.uppercased()
        let quote = quote.uppercased()
        guard CurrencyConversionEngine.supportedCodes.contains(base),
              CurrencyConversionEngine.supportedCodes.contains(quote) else { return nil }
        self.base = base
        self.quote = quote
    }
}

public struct CurrencyRateSnapshot: Codable, Equatable, Sendable {
    public let pair: CurrencyPair
    /// Number of quote currency units for one base currency unit.
    public let rate: Double
    /// The observation date returned by the rate provider.
    public let rateDate: Date
    /// When this device last downloaded the observation.
    public let fetchedAt: Date

    public func isStale(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(fetchedAt) > CurrencyRateCachePolicy.freshnessInterval
    }

    public init(pair: CurrencyPair, rate: Double, rateDate: Date, fetchedAt: Date = Date()) {
        self.pair = pair
        self.rate = rate
        self.rateDate = rateDate
        self.fetchedAt = fetchedAt
    }
}

struct CurrencyConversionEngine {
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    func evaluate(_ input: String, rates: [CurrencyRateSnapshot], now: Date) -> SpecializedCalculation {
        guard let parts = Self.conversionParts(in: input) else { return .notHandled }
        guard let source = Self.parseAmountAndCurrency(parts.source) else { return .notHandled }
        if parts.target.isEmpty { return .incomplete }
        guard let targetCode = Self.currencyCode(named: parts.target) else {
            if UnitConversionEngine(locale: locale).recognizesUnit(named: parts.target) { return .notHandled }
            return .failure("Unknown currency “\(parts.target)”.")
        }
        guard let pair = CurrencyPair(base: source.code, quote: targetCode) else { return .notHandled }

        if pair.base == pair.quote {
            return .result("\(format(source.amount)) \(pair.quote)")
        }

        let matchingRate = rates
            .filter { $0.rate.isFinite && $0.rate > 0 }
            .sorted { $0.fetchedAt > $1.fetchedAt }
            .first { $0.pair == pair || ($0.pair.base == pair.quote && $0.pair.quote == pair.base) }

        guard let snapshot = matchingRate else {
            return .failure("No saved exchange rate is available. Connect to the internet and try again.")
        }

        let rate = snapshot.pair == pair ? snapshot.rate : 1 / snapshot.rate
        let converted = source.amount * rate
        guard converted.isFinite else {
            return .failure("The converted value is outside the supported range.")
        }

        let cachedSuffix = snapshot.isStale(at: now) ? ", cached" : ""
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let date = dateFormatter.string(from: snapshot.rateDate)
        let amount = "\(format(converted)) \(pair.quote)"
        return .resultWithClipboard(display: "\(amount) (rate dated \(date)\(cachedSuffix))", clipboard: amount)
    }

    static func pair(in input: String) -> CurrencyPair? {
        guard input.count <= 512,
              let parts = conversionParts(in: input),
              let source = parseAmountAndCurrency(parts.source),
              let target = currencyCode(named: parts.target) else { return nil }
        return CurrencyPair(base: source.code, quote: target)
    }

    private func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private static func conversionParts(in input: String) -> (source: String, target: String)? {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)\s+(to|in|as)(?=\s|$)"#) else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = expression.matches(in: input, range: range).last,
              let swiftRange = Range(match.range, in: input) else { return nil }
        let source = String(input[..<swiftRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let target = String(input[swiftRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        return (source, target)
    }

    private static func parseAmountAndCurrency(_ text: String) -> (amount: Double, code: String)? {
        let number = #"[+-]?(?:[0-9]+(?:[.,][0-9]*)?|[.,][0-9]+)(?:[eE][+-]?[0-9]+)?"#
        if let match = firstMatch(of: #"^\s*("# + number + #")\s*(.*?)\s*$"#, in: text),
           let amountRange = Range(match.range(at: 1), in: text),
           let currencyRange = Range(match.range(at: 2), in: text),
           let code = currencyCode(named: String(text[currencyRange])) {
            let literal = String(text[amountRange]).replacingOccurrences(of: ",", with: ".")
            if let amount = Double(literal), amount.isFinite { return (amount, code) }
        }

        if let match = firstMatch(of: #"^\s*(.*?)\s*("# + number + #")\s*$"#, in: text),
           let currencyRange = Range(match.range(at: 1), in: text),
           let amountRange = Range(match.range(at: 2), in: text),
           let code = currencyCode(named: String(text[currencyRange])) {
            let literal = String(text[amountRange]).replacingOccurrences(of: ",", with: ".")
            if let amount = Double(literal), amount.isFinite { return (amount, code) }
        }
        return nil
    }

    private static func firstMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func currencyCode(named rawName: String) -> String? {
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if normalized.count == 3, supportedCodes.contains(normalized.uppercased()) {
            return normalized.uppercased()
        }
        return aliases[normalized]
    }

    fileprivate static let supportedCodes: Set<String> = [
        "AED", "AUD", "BGN", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF",
        "IDR", "ILS", "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON",
        "RUB", "SAR", "SEK", "SGD", "THB", "TRY", "TWD", "UAH", "USD", "VND", "ZAR"
    ]

    private static let aliases: [String: String] = [
        "$": "USD", "us$": "USD", "usd": "USD", "dollar": "USD", "dollars": "USD", "us dollar": "USD", "us dollars": "USD", "🇺🇸": "USD",
        "€": "EUR", "eur": "EUR", "euro": "EUR", "euros": "EUR",
        "£": "GBP", "gbp": "GBP", "pound": "GBP", "pounds": "GBP", "british pound": "GBP", "sterling": "GBP",
        "¥": "JPY", "jp¥": "JPY", "jpy": "JPY", "yen": "JPY", "yens": "JPY",
        "cn¥": "CNY", "cny": "CNY", "yuan": "CNY", "renminbi": "CNY", "rmb": "CNY",
        "ca$": "CAD", "cad": "CAD", "canadian dollar": "CAD", "canadian dollars": "CAD",
        "a$": "AUD", "aud": "AUD", "australian dollar": "AUD", "australian dollars": "AUD",
        "nzd": "NZD", "new zealand dollar": "NZD", "new zealand dollars": "NZD",
        "chf": "CHF", "swiss franc": "CHF", "swiss francs": "CHF",
        "pln": "PLN", "zł": "PLN", "zloty": "PLN", "złoty": "PLN", "zlotys": "PLN", "złote": "PLN",
        "sek": "SEK", "swedish krona": "SEK", "swedish kronor": "SEK",
        "nok": "NOK", "norwegian krone": "NOK", "norwegian kroner": "NOK",
        "dkk": "DKK", "danish krone": "DKK", "danish kroner": "DKK",
        "czk": "CZK", "czech koruna": "CZK", "czech korunas": "CZK",
        "huf": "HUF", "forint": "HUF", "forints": "HUF",
        "ron": "RON", "romanian leu": "RON", "lei": "RON",
        "bgn": "BGN", "bulgarian lev": "BGN", "leva": "BGN",
        "inr": "INR", "₹": "INR", "rupee": "INR", "rupees": "INR", "indian rupee": "INR", "indian rupees": "INR",
        "sgd": "SGD", "s$": "SGD", "singapore dollar": "SGD", "singapore dollars": "SGD",
        "hkd": "HKD", "hk$": "HKD", "hong kong dollar": "HKD", "hong kong dollars": "HKD",
        "krw": "KRW", "₩": "KRW", "south korean won": "KRW", "won": "KRW",
        "mxn": "MXN", "mexican peso": "MXN", "mexican pesos": "MXN",
        "brl": "BRL", "r$": "BRL", "brazilian real": "BRL", "reais": "BRL",
        "zar": "ZAR", "south african rand": "ZAR", "rand": "ZAR", "rands": "ZAR",
        "rub": "RUB", "₽": "RUB", "russian ruble": "RUB", "ruble": "RUB", "rubles": "RUB",
        "thb": "THB", "฿": "THB", "thai baht": "THB", "baht": "THB",
        "idr": "IDR", "indonesian rupiah": "IDR", "rupiah": "IDR",
        "myr": "MYR", "rm": "MYR", "malaysian ringgit": "MYR", "ringgit": "MYR",
        "php": "PHP", "₱": "PHP", "philippine peso": "PHP", "philippine pesos": "PHP",
        "ils": "ILS", "₪": "ILS", "israeli new shekel": "ILS", "shekel": "ILS", "shekels": "ILS",
        "aed": "AED", "د.إ": "AED", "uae dirham": "AED", "dirham": "AED", "dirhams": "AED",
        "sar": "SAR", "﷼": "SAR", "saudi riyal": "SAR", "riyal": "SAR", "riyals": "SAR",
        "twd": "TWD", "nt$": "TWD", "taiwan dollar": "TWD", "taiwan dollars": "TWD",
        "isk": "ISK", "icelandic krona": "ISK", "icelandic kronur": "ISK",
        "try": "TRY", "₺": "TRY", "turkish lira": "TRY", "lira": "TRY",
        "uah": "UAH", "₴": "UAH", "ukrainian hryvnia": "UAH", "hryvnia": "UAH",
        "vnd": "VND", "₫": "VND", "vietnamese dong": "VND", "dong": "VND"
    ]
}

public enum CurrencyRateCachePolicy {
    public static let freshnessInterval: TimeInterval = 24 * 60 * 60
    public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumEntries = 64
}
