import Combine
import Foundation
import KebloopCore

struct CurrencyRateHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let expectedContentLength: Int64
}

protocol CurrencyRateLoading: Sendable {
    func load(_ request: URLRequest) async throws -> CurrencyRateHTTPResponse
}

private struct URLSessionCurrencyRateLoader: CurrencyRateLoading {
    let session: URLSession

    func load(_ request: URLRequest) async throws -> CurrencyRateHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.expectedContentLength < 0 || response.expectedContentLength <= 32 * 1024 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return CurrencyRateHTTPResponse(data: Data(), statusCode: statusCode, expectedContentLength: response.expectedContentLength)
        }
        var data = Data()
        data.reserveCapacity(512)
        for try await byte in bytes {
            guard data.count < 32 * 1024 else {
                return CurrencyRateHTTPResponse(data: Data(), statusCode: response.statusCode, expectedContentLength: 32 * 1024 + 1)
            }
            data.append(byte)
        }
        return CurrencyRateHTTPResponse(data: data, statusCode: response.statusCode, expectedContentLength: response.expectedContentLength)
    }
}

/// Fetches one pair only when a currency conversion is entered and keeps a small
/// on-device cache so a recent rate remains available when the network is offline.
@MainActor
final class CurrencyRateStore: ObservableObject {
    @Published private(set) var snapshots: [CurrencyRateSnapshot]

    private let defaults: UserDefaults
    private let loader: any CurrencyRateLoading
    private let apiBaseURL: URL
    private let now: () -> Date
    private var activePairs = Set<CurrencyPair>()
    private var lastAttemptAt: [CurrencyPair: Date] = [:]

    static let cacheKey = "currencyRateSnapshots.v1"
    private static let maximumCacheBytes = 64 * 1024
    private static let retryDelay: TimeInterval = 30
    nonisolated private static let apiBaseURL = URL(string: "https://api.frankfurter.dev")!

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        loader: (any CurrencyRateLoading)? = nil,
        apiBaseURL: URL = CurrencyRateStore.apiBaseURL,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.loader = loader ?? URLSessionCurrencyRateLoader(session: session)
        self.apiBaseURL = apiBaseURL
        self.now = now
        let cached = defaults.data(forKey: Self.cacheKey)
            .flatMap { $0.count <= Self.maximumCacheBytes ? try? JSONDecoder().decode([CurrencyRateSnapshot].self, from: $0) : nil } ?? []
        snapshots = Self.retained(cached, now: now())
        if snapshots != cached { persist() }
    }

    func snapshot(for pair: CurrencyPair) -> CurrencyRateSnapshot? {
        snapshots
            .filter { $0.pair == pair || ($0.pair.base == pair.quote && $0.pair.quote == pair.base) }
            .max { $0.fetchedAt < $1.fetchedAt }
    }

    func isRefreshing(pair: CurrencyPair) -> Bool {
        activePairs.contains(pair)
    }

    /// Safe to call as the query changes: ordinary queries are ignored, fresh pairs
    /// are not fetched again, and repeated input for an in-flight pair is coalesced.
    func refreshIfNeeded(for input: String) async {
        guard let pair = CalculatorEngine.currencyPair(in: input) else { return }
        await refreshIfNeeded(for: pair)
    }

    func refreshIfNeeded(for pair: CurrencyPair) async {
        guard pair.base != pair.quote else { return }
        let currentDate = now()
        if let cached = snapshot(for: pair), currentDate.timeIntervalSince(cached.fetchedAt) < CurrencyRateCachePolicy.freshnessInterval {
            return
        }
        if let lastAttempt = lastAttemptAt[pair], currentDate.timeIntervalSince(lastAttempt) < Self.retryDelay { return }
        guard activePairs.insert(pair).inserted else { return }
        lastAttemptAt[pair] = currentDate
        defer { activePairs.remove(pair) }

        guard let downloaded = await fetch(pair) else { return }
        snapshots = Self.retained((snapshots.filter { $0.pair != pair } + [downloaded]), now: now())
        persist()
    }

    private func fetch(_ pair: CurrencyPair) async -> CurrencyRateSnapshot? {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v2/rate/\(pair.base.lowercased())/\(pair.quote.lowercased())"
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let response = try await loader.load(request)
            guard response.statusCode >= 200, response.statusCode < 300,
                  response.data.count <= 32 * 1024,
                  response.expectedContentLength < 0 || response.expectedContentLength <= 32 * 1024 else { return nil }
            let data = response.data
            let payload = try JSONDecoder().decode(ProviderRate.self, from: data)
            guard payload.base.uppercased() == pair.base,
                  payload.quote.uppercased() == pair.quote,
                  payload.rate.isFinite, payload.rate > 0,
                  let rateDate = Self.parseProviderDate(payload.date),
                  rateDate <= now().addingTimeInterval(24 * 60 * 60) else { return nil }
            return CurrencyRateSnapshot(pair: pair, rate: payload.rate, rateDate: rateDate, fetchedAt: now())
        } catch {
            return nil
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshots), data.count <= Self.maximumCacheBytes else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }

    private static func retained(_ values: [CurrencyRateSnapshot], now: Date) -> [CurrencyRateSnapshot] {
        var latestByPair: [CurrencyPair: CurrencyRateSnapshot] = [:]
        for snapshot in values where snapshot.rate.isFinite && snapshot.rate > 0 {
            let age = now.timeIntervalSince(snapshot.fetchedAt)
            guard age >= 0, age <= CurrencyRateCachePolicy.maximumAge else { continue }
            if let previous = latestByPair[snapshot.pair], previous.fetchedAt >= snapshot.fetchedAt { continue }
            latestByPair[snapshot.pair] = snapshot
        }
        return latestByPair.values.sorted { $0.fetchedAt > $1.fetchedAt }.prefix(CurrencyRateCachePolicy.maximumEntries).map { $0 }
    }

    private static func parseProviderDate(_ rawValue: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: rawValue)
    }

    private struct ProviderRate: Decodable {
        let date: String
        let base: String
        let quote: String
        let rate: Double
    }
}
