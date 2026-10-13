import Combine
import Foundation
import KebloopCore

struct CalculationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let expression: String
    let display: String
    let clipboard: String?
    let acceptedAt: Date

    var result: CalculationResult {
        CalculationResult(expression: expression, display: display, clipboard: clipboard ?? display)
    }
}

/// Stores only calculations the user explicitly accepted or copied.
@MainActor
final class CalculationHistoryStore: ObservableObject {
    @Published private(set) var entries: [CalculationHistoryEntry]

    private let defaults: UserDefaults
    private let now: () -> Date
    private static let key = "calculationHistory.v1"
    private static let maximumEntries = 100
    private static let maximumEncodedBytes = 128 * 1024
    private static let maximumFieldBytes = 2 * 1024

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        let cached = defaults.data(forKey: Self.key)
            .flatMap { $0.count <= Self.maximumEncodedBytes ? try? JSONDecoder().decode([CalculationHistoryEntry].self, from: $0) : nil } ?? []
        entries = Array(cached.prefix(Self.maximumEntries).filter(Self.isValid))
    }

    func recordAccepted(_ result: CalculationResult) {
        let expression = String(result.expression.prefix(Self.maximumFieldBytes))
        let display = String(result.display.prefix(Self.maximumFieldBytes))
        guard !expression.isEmpty, !display.isEmpty,
              expression.utf8.count <= Self.maximumFieldBytes,
              display.utf8.count <= Self.maximumFieldBytes else { return }
        let clipboard = String(result.clipboard.prefix(Self.maximumFieldBytes))
        guard clipboard.utf8.count <= Self.maximumFieldBytes else { return }
        let entry = CalculationHistoryEntry(id: UUID().uuidString, expression: expression, display: display, clipboard: clipboard, acceptedAt: now())
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.maximumEntries))
        persist()
    }

    func clear() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.key)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries), data.count <= Self.maximumEncodedBytes else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func isValid(_ entry: CalculationHistoryEntry) -> Bool {
        !entry.id.isEmpty
            && !entry.expression.isEmpty
            && !entry.display.isEmpty
            && entry.expression.utf8.count <= maximumFieldBytes
            && entry.display.utf8.count <= maximumFieldBytes
            && (entry.clipboard?.utf8.count ?? 0) <= maximumFieldBytes
    }
}
