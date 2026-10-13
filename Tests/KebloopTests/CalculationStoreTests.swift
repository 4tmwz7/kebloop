import Foundation
import KebloopCore
import XCTest
@testable import Kebloop

@MainActor
final class CalculationStoreTests: XCTestCase {
    func testHistoryPersistsOnlyAcceptedCalculationsAndPreservesClipboardText() throws {
        let defaults = isolatedDefaults()
        let acceptedAt = Date(timeIntervalSince1970: 1_791_000_000)
        let store = CalculationHistoryStore(defaults: defaults, now: { acceptedAt })
        XCTAssertTrue(store.entries.isEmpty)

        store.recordAccepted(CalculationResult(expression: "2 + 2", display: "4", clipboard: "four"))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].result.clipboard, "four")
        XCTAssertEqual(store.entries[0].acceptedAt, acceptedAt)

        let reloaded = CalculationHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries, store.entries)
        reloaded.clear()
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "calculationHistory.v1"))
    }

    func testHistoryKeepsAtMostOneHundredAcceptedEntries() {
        let store = CalculationHistoryStore(defaults: isolatedDefaults())
        for value in 0..<101 {
            store.recordAccepted(CalculationResult(expression: "\(value) + 1", display: "\(value + 1)", clipboard: "\(value + 1)"))
        }
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertEqual(store.entries.first?.expression, "100 + 1")
    }

    func testCurrencyCacheIsBoundedAndKeepsRecentRatesForOfflineUse() throws {
        let defaults = isolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let codes = ["USD", "EUR", "GBP", "JPY", "CNY", "CAD", "AUD", "NZD", "CHF", "PLN", "SEK", "NOK"]
        var snapshots: [CurrencyRateSnapshot] = []
        for base in codes {
            for quote in codes where base != quote
                && !(base == "USD" && quote == "EUR")
                && !(base == "EUR" && quote == "USD")
                && !(base == "EUR" && quote == "GBP") {
                guard let pair = CurrencyPair(base: base, quote: quote) else { continue }
                snapshots.append(CurrencyRateSnapshot(
                    pair: pair,
                    rate: 1.25,
                    rateDate: now.addingTimeInterval(-86_400),
                    fetchedAt: now.addingTimeInterval(-Double(snapshots.count))
                ))
            }
        }
        let stalePair = CurrencyPair(base: "USD", quote: "EUR")!
        snapshots = Array(snapshots.prefix(CurrencyRateCachePolicy.maximumEntries - 1)) + [CurrencyRateSnapshot(
            pair: stalePair,
            rate: 0.9,
            rateDate: now.addingTimeInterval(-86_400),
            fetchedAt: now.addingTimeInterval(-2 * 86_400)
        ), CurrencyRateSnapshot(
            pair: CurrencyPair(base: "EUR", quote: "GBP")!,
            rate: 0.8,
            rateDate: now.addingTimeInterval(-3 * 86_400),
            fetchedAt: now.addingTimeInterval(-3 * 86_400)
        )]
        defaults.set(try JSONEncoder().encode(snapshots), forKey: CurrencyRateStore.cacheKey)

        let store = CurrencyRateStore(defaults: defaults, now: { now })
        XCTAssertEqual(store.snapshots.count, CurrencyRateCachePolicy.maximumEntries)
        XCTAssertEqual(store.snapshot(for: stalePair)?.rate, 0.9)
        XCTAssertTrue(store.snapshot(for: stalePair)?.isStale(at: now) == true)

        let expiredDefaults = isolatedDefaults()
        let expired = CurrencyRateSnapshot(
            pair: stalePair,
            rate: 0.9,
            rateDate: now.addingTimeInterval(-40 * 86_400),
            fetchedAt: now.addingTimeInterval(-40 * 86_400)
        )
        expiredDefaults.set(try JSONEncoder().encode([expired]), forKey: CurrencyRateStore.cacheKey)
        let expiredStore = CurrencyRateStore(defaults: expiredDefaults, now: { now })
        XCTAssertTrue(expiredStore.snapshots.isEmpty)
    }

    func testCurrencyRateFetchUsesPairEndpointAndCoalescesConcurrentRequests() async throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let body = Data(#"{"date":"2026-10-02","base":"USD","quote":"PLN","rate":3.75}"#.utf8)
        let loader = MockCurrencyRateLoader(response: CurrencyRateHTTPResponse(data: body, statusCode: 200, expectedContentLength: Int64(body.count)), delay: true)
        let store = CurrencyRateStore(defaults: isolatedDefaults(), loader: loader, now: { now })

        async let first: Void = store.refreshIfNeeded(for: "100 USD to PLN")
        async let second: Void = store.refreshIfNeeded(for: "100 USD to PLN")
        _ = await (first, second)

        let requestPaths = await loader.requestPaths()
        let acceptHeaders = await loader.acceptHeaders()
        XCTAssertEqual(requestPaths, ["/v2/rate/usd/pln"])
        XCTAssertEqual(acceptHeaders, ["application/json"])
        XCTAssertEqual(store.snapshot(for: CurrencyPair(base: "USD", quote: "PLN")!)?.rate, 3.75)
        XCTAssertNil(CalculatorEngine.currencyPair(in: String(repeating: "x", count: 513)))
    }

    func testInvalidRateResponseKeepsStaleCacheAvailableOffline() async throws {
        let defaults = isolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let pair = CurrencyPair(base: "USD", quote: "PLN")!
        let cached = CurrencyRateSnapshot(
            pair: pair,
            rate: 3.5,
            rateDate: now.addingTimeInterval(-2 * 86_400),
            fetchedAt: now.addingTimeInterval(-2 * 86_400)
        )
        defaults.set(try JSONEncoder().encode([cached]), forKey: CurrencyRateStore.cacheKey)

        let invalidBody = Data(#"{"date":"2026-10-02","base":"USD","quote":"PLN","rate":0}"#.utf8)
        let loader = MockCurrencyRateLoader(response: CurrencyRateHTTPResponse(data: invalidBody, statusCode: 200, expectedContentLength: Int64(invalidBody.count)))
        let store = CurrencyRateStore(defaults: defaults, loader: loader, now: { now })
        await store.refreshIfNeeded(for: pair)

        XCTAssertEqual(store.snapshots.count, 1)
        guard case .result(let result) = CalculatorEngine(locale: Locale(identifier: "en_US"), referenceDate: now)
            .evaluate("100 USD to PLN", currencyRates: store.snapshots) else {
            return XCTFail("The cached rate should remain available after an invalid network response")
        }
        XCTAssertTrue(result.display.contains("cached"))

        let tooLarge = MockCurrencyRateLoader(response: CurrencyRateHTTPResponse(
            data: Data(repeating: 65, count: 32 * 1024 + 1),
            statusCode: 200,
            expectedContentLength: 32 * 1024 + 1
        ))
        let emptyStore = CurrencyRateStore(defaults: isolatedDefaults(), loader: tooLarge, now: { now })
        await emptyStore.refreshIfNeeded(for: pair)
        XCTAssertTrue(emptyStore.snapshots.isEmpty)
    }

    private func isolatedDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: "CalculationStoreTests-\(UUID().uuidString)") else {
            fatalError("Could not create isolated test defaults")
        }
        return defaults
    }
}

private actor MockCurrencyRateLoader: CurrencyRateLoading {
    private let response: CurrencyRateHTTPResponse
    private let delay: Bool
    private var requests: [URLRequest] = []

    init(response: CurrencyRateHTTPResponse, delay: Bool = false) {
        self.response = response
        self.delay = delay
    }

    func load(_ request: URLRequest) async throws -> CurrencyRateHTTPResponse {
        requests.append(request)
        if delay { try await Task.sleep(nanoseconds: 20_000_000) }
        return response
    }

    func requestPaths() -> [String] {
        requests.compactMap { $0.url?.path }
    }

    func acceptHeaders() -> [String] {
        requests.map { $0.value(forHTTPHeaderField: "Accept") ?? "" }
    }
}
