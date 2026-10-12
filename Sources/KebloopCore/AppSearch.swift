import Foundation

public struct AppSearchEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String

    public init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// Ranks applications by exact matches, prefixes, word prefixes, and fuzzy subsequences.
public struct AppSearch {
    public init() {}

    public func ranked(
        query: String,
        entries: [AppSearchEntry],
        usage: [String: Int] = [:]
    ) -> [AppSearchEntry] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return entries.sorted { left, right in
                let leftUsage = usage[left.id, default: 0]
                let rightUsage = usage[right.id, default: 0]
                if leftUsage != rightUsage { return leftUsage > rightUsage }
                return Self.stableNameOrder(left, right)
            }
        }

        let queryWords = Self.words(in: normalizedQuery)
        return entries
            .compactMap { entry -> (entry: AppSearchEntry, score: Int, usage: Int)? in
                let name = Self.normalize(entry.name)
                guard let matchScore = Self.matchScore(
                    query: normalizedQuery,
                    queryWords: queryWords,
                    name: name
                ) else { return nil }

                return (
                    entry,
                    matchScore + Self.usageBoost(usage[entry.id, default: 0]),
                    max(0, usage[entry.id, default: 0])
                )
            }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                if left.usage != right.usage { return left.usage > right.usage }
                return Self.stableNameOrder(left.entry, right.entry)
            }
            .map(\.entry)
    }

    private static func matchScore(query: String, queryWords: [String], name: String) -> Int? {
        if name == query { return 1_200 }

        if name.hasPrefix(query) {
            return 1_100 - min(50, name.count - query.count)
        }

        let nameWords = words(in: name)
        if let wordPrefixScore = wordPrefixScore(queryWords: queryWords, nameWords: nameWords) {
            return wordPrefixScore
        }

        return subsequenceScore(query: query, name: name)
    }

    private static func wordPrefixScore(queryWords: [String], nameWords: [String]) -> Int? {
        guard !queryWords.isEmpty, !nameWords.isEmpty else { return nil }

        var nextNameWord = 0
        var matchedPositions: [Int] = []
        for queryWord in queryWords {
            guard let position = nameWords.indices.first(where: {
                $0 >= nextNameWord && nameWords[$0].hasPrefix(queryWord)
            }) else { return nil }
            matchedPositions.append(position)
            nextNameWord = position + 1
        }

        let positionPenalty = matchedPositions.reduce(0, +) * 12
        if queryWords.count > 1 {
            return 950 - min(100, positionPenalty)
        }
        return 900 - min(100, positionPenalty)
    }

    private static func subsequenceScore(query: String, name: String) -> Int? {
        let queryCharacters = Array(query)
        let nameCharacters = Array(name)
        guard !queryCharacters.isEmpty, queryCharacters.count <= nameCharacters.count else { return nil }

        var positions: [Int] = []
        var searchStart = 0
        for character in queryCharacters {
            guard let position = nameCharacters[searchStart...].firstIndex(of: character) else {
                return nil
            }
            positions.append(position)
            searchStart = position + 1
        }

        let gaps = zip(positions, positions.dropFirst()).reduce(into: 0) { total, pair in
            total += pair.1 - pair.0 - 1
        }
        let wordStarts = positions.reduce(into: 0) { total, position in
            if position == 0 || !nameCharacters[position - 1].isLetter && !nameCharacters[position - 1].isNumber {
                total += 1
            }
        }
        let adjacentPairs = positions.dropFirst().enumerated().reduce(into: 0) { total, item in
            if item.element == positions[item.offset] + 1 { total += 1 }
        }

        return 700 - min(50, positions[0] * 2) - min(80, gaps * 4)
            + min(30, wordStarts * 10) + min(20, adjacentPairs * 5)
    }

    private static func usageBoost(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        // Usage helps choose between similar matches without outranking a stronger match class.
        return min(24, Int(log2(Double(count) + 1) * 3))
    }

    private static func normalize(_ string: String) -> String {
        let folded = string.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return words(in: folded).joined(separator: " ")
    }

    private static func words(in string: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            guard !current.isEmpty else { return }
            result.append(String(current))
            current = String.UnicodeScalarView()
        }

        for scalar in string.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private static func stableNameOrder(_ left: AppSearchEntry, _ right: AppSearchEntry) -> Bool {
        let leftName = normalize(left.name)
        let rightName = normalize(right.name)
        if leftName != rightName { return leftName < rightName }
        if left.name != right.name { return left.name < right.name }
        return left.id < right.id
    }
}
