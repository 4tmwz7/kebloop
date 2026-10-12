import Foundation

public struct AppSearchEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let aliases: [String]

    public init(id: String, name: String, path: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.aliases = aliases
    }
}

/// Ranks applications by exact matches, prefixes, word prefixes, and fuzzy subsequences.
public struct AppSearch {
    public init() {}

    private struct PreparedEntry {
        let entry: AppSearchEntry
        let normalizedName: String
        let usage: Int
    }

    private struct ScoredEntry {
        let entry: AppSearchEntry
        let normalizedName: String
        let score: Int
        let usage: Int
    }

    public func ranked(
        query: String,
        entries: [AppSearchEntry],
        usage: [String: Int] = [:]
    ) -> [AppSearchEntry] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return entries.map { entry in
                PreparedEntry(
                    entry: entry,
                    normalizedName: Self.normalize(entry.name),
                    usage: usage[entry.id, default: 0]
                )
            }.sorted { left, right in
                if left.usage != right.usage { return left.usage > right.usage }
                return Self.stableNameOrder(
                    left.entry,
                    left.normalizedName,
                    right.entry,
                    right.normalizedName
                )
            }.map(\.entry)
        }

        let queryWords = Self.words(in: normalizedQuery)
        let queryCharacters = Array(normalizedQuery)
        return entries
            .compactMap { entry -> ScoredEntry? in
                let normalizedName = Self.normalize(entry.name)
                let entryUsage = usage[entry.id, default: 0]
                let nameScore = Self.matchScore(
                    query: normalizedQuery,
                    queryCharacters: queryCharacters,
                    queryWords: queryWords,
                    name: normalizedName
                )
                let aliasScore = entry.aliases.compactMap { alias in
                    Self.aliasMatchScore(
                        query: normalizedQuery,
                        queryCharacters: queryCharacters,
                        queryWords: queryWords,
                        alias: alias
                    )
                }.max()
                guard let matchScore = [nameScore, aliasScore].compactMap({ $0 }).max() else { return nil }

                return ScoredEntry(
                    entry: entry,
                    normalizedName: normalizedName,
                    score: matchScore + Self.usageBoost(entryUsage),
                    usage: max(0, entryUsage)
                )
            }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                if left.usage != right.usage { return left.usage > right.usage }
                return Self.stableNameOrder(
                    left.entry,
                    left.normalizedName,
                    right.entry,
                    right.normalizedName
                )
            }
            .map(\.entry)
    }

    private static func matchScore(
        query: String,
        queryCharacters: [Character],
        queryWords: [String],
        name: String
    ) -> Int? {
        if name == query { return 1_200 }

        if name.hasPrefix(query) {
            return 1_100 - min(50, name.count - query.count)
        }

        let nameWords = words(in: name)
        if let wordPrefixScore = wordPrefixScore(queryWords: queryWords, nameWords: nameWords) {
            return wordPrefixScore
        }

        return subsequenceScore(queryCharacters: queryCharacters, name: name)
    }

    private static func aliasMatchScore(
        query: String,
        queryCharacters: [Character],
        queryWords: [String],
        alias: String
    ) -> Int? {
        let normalizedAlias = normalize(alias)
        guard !normalizedAlias.isEmpty else { return nil }

        // An exact alias should win over an exact application name. Prefix aliases
        // remain below exact names and above ordinary name prefixes.
        if normalizedAlias == query { return 1_400 }
        if normalizedAlias.hasPrefix(query) {
            return 1_170 - min(20, normalizedAlias.count - query.count)
        }

        let aliasWords = words(in: normalizedAlias)
        if let prefixScore = wordPrefixScore(queryWords: queryWords, nameWords: aliasWords) {
            return prefixScore + 10
        }

        return subsequenceScore(queryCharacters: queryCharacters, name: normalizedAlias).map { $0 + 15 }
    }

    private static func wordPrefixScore(queryWords: [String], nameWords: [String]) -> Int? {
        guard !queryWords.isEmpty, !nameWords.isEmpty else { return nil }

        var nextNameWord = 0
        var positionPenalty = 0
        for queryWord in queryWords {
            guard let position = nameWords.indices.first(where: {
                $0 >= nextNameWord && nameWords[$0].hasPrefix(queryWord)
            }) else { return nil }
            positionPenalty += position * 12
            nextNameWord = position + 1
        }

        if queryWords.count > 1 {
            return 950 - min(100, positionPenalty)
        }
        return 900 - min(100, positionPenalty)
    }

    private static func subsequenceScore(queryCharacters: [Character], name: String) -> Int? {
        let nameCharacters = Array(name)
        guard !queryCharacters.isEmpty, queryCharacters.count <= nameCharacters.count else { return nil }

        var firstPosition: Int?
        var previousPosition: Int?
        var gaps = 0
        var wordStarts = 0
        var adjacentPairs = 0
        var searchStart = 0
        for character in queryCharacters {
            guard let position = nameCharacters[searchStart...].firstIndex(of: character) else {
                return nil
            }
            if firstPosition == nil {
                firstPosition = position
            } else if let previousPosition {
                gaps += position - previousPosition - 1
                if position == previousPosition + 1 { adjacentPairs += 1 }
            }
            if position == 0 || !nameCharacters[position - 1].isLetter && !nameCharacters[position - 1].isNumber {
                wordStarts += 1
            }
            previousPosition = position
            searchStart = position + 1
        }

        guard let firstPosition else { return nil }
        return 700 - min(50, firstPosition * 2) - min(80, gaps * 4)
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

    private static func stableNameOrder(
        _ left: AppSearchEntry,
        _ normalizedLeftName: String,
        _ right: AppSearchEntry,
        _ normalizedRightName: String
    ) -> Bool {
        if normalizedLeftName != normalizedRightName { return normalizedLeftName < normalizedRightName }
        if left.name != right.name { return left.name < right.name }
        return left.id < right.id
    }
}
