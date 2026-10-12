import Combine
import Foundation

struct FileSearchResult: Identifiable, Hashable, Sendable {
    let name: String
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    static let libraryPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path

    static func isVisibleFile(path: String) -> Bool {
        guard !FileSearchExclusions.isTemporary(path: path), path != libraryPath, !path.hasPrefix(libraryPath + "/") else { return false }
        return !path.split(separator: "/").contains { component in
            component.hasPrefix(".") || component == "node_modules" || ["app", "bundle", "framework", "plugin", "appex"].contains(
                (String(component) as NSString).pathExtension.lowercased()
            )
        }
    }

    static func ranked(_ files: [FileSearchResult], for text: String) -> [FileSearchResult] {
        let query = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["Documents", "Desktop", "Downloads", "Public"].map { home + "/" + $0 + "/" }
        func score(_ file: FileSearchResult) -> Int {
            let name = file.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let stem = (name as NSString).deletingPathExtension
            let relevance = name == query || stem == query ? 3 : (name.hasPrefix(query) ? 2 : 1)
            return relevance * 10 + (folders.contains(where: { file.path.hasPrefix($0) }) ? 1 : 0)
        }
        let scores = files.map { (file: $0, score: score($0)) }
        return scores.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let nameOrder = $0.file.name.localizedStandardCompare($1.file.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.file.path < $1.file.path
        }.map(\.file)
    }
}

// Small, recent query snapshots make backspacing and narrowing a query immediate.
// They remain provisional: Spotlight still refreshes every search for new matches.
struct FileSearchCache {
    private var entries: [(text: String, results: [FileSearchResult])] = []
    private let capacity = 12

    mutating func store(_ results: [FileSearchResult], for text: String) {
        let key = Self.key(text)
        entries.removeAll { $0.text == key }
        entries.insert((key, Array(results.prefix(40))), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    func matching(_ text: String) -> [FileSearchResult] {
        let key = Self.key(text)
        guard !key.isEmpty,
              let entry = entries.first(where: { $0.text == key })
                ?? entries.first(where: { key.contains($0.text) }) else { return [] }
        return FileSearchResult.ranked(entry.results.filter {
            $0.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }, for: text)
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

// Shared with the worker queue so cancelled searches stop before more Git checks.
private final class FileFilterRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
}

@MainActor
final class FileSearchService: ObservableObject {
    @Published private(set) var results: [FileSearchResult] = []
    @Published private(set) var isSearching = false

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var generation = 0
    private var cache = FileSearchCache()
    private let exclusions = FileSearchExclusions()
    private let filterQueue = DispatchQueue(label: "Kebloop.file-exclusions", qos: .userInitiated)
    private var filterRequest: FileFilterRequest?

    func search(_ text: String) {
        stop()
        let searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else { return }
        isSearching = true
        let token = generation
        let cached = cache.matching(searchText)
        if !cached.isEmpty { publishFiltered(cached, text: searchText, generation: token, finished: false) }
        debounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.start(searchText, generation: token)
        }
    }

    func stop() {
        generation &+= 1
        filterRequest?.cancel()
        filterRequest = nil
        debounceTask?.cancel()
        debounceTask = nil
        query?.stop()
        query = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        results = []
        isSearching = false
    }

    private func start(_ text: String, generation: Int) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        // Filter packages and hidden paths inside Spotlight before bounded collection.
        var predicates = [NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text),
                          NSPredicate(format: "NOT (%K CONTAINS %@)", NSMetadataItemPathKey, "/."),
                          NSPredicate(format: "NOT (%K BEGINSWITH %@)", NSMetadataItemPathKey, FileSearchResult.libraryPath + "/"),
                          NSPredicate(format: "%K != %@", NSMetadataItemPathKey, FileSearchResult.libraryPath),
                          NSPredicate(format: "NOT (%K CONTAINS %@)", NSMetadataItemPathKey, "/node_modules/"),
                          NSPredicate(format: "NOT (%K ENDSWITH %@)", NSMetadataItemPathKey, "/node_modules")]
        for suffix in ["app", "bundle", "framework", "plugin", "appex"] {
            predicates.append(NSPredicate(format: "NOT (%K ENDSWITH[cd] %@)", NSMetadataItemPathKey, ".\(suffix)"))
            predicates.append(NSPredicate(format: "NOT (%K LIKE[cd] %@)", NSMetadataItemPathKey, "*.\(suffix)/*"))
        }
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        query.notificationBatchingInterval = 0.03
        self.query = query
        for name in [NSNotification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) {
                [weak self] notification in
                let finished = notification.name == .NSMetadataQueryDidFinishGathering
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, let activeQuery = self.query else { return }
                    self.collect(activeQuery, text: text, finished: finished)
                }
            })
        }
        if !query.start() { isSearching = false }
    }

    private func collect(_ query: NSMetadataQuery, text: String, finished: Bool, cursor: Int = 0, accumulated: [FileSearchResult] = []) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var collected: [FileSearchResult] = []
        var paths = Set<String>()
        // Never walk an unbounded Spotlight result set on the input/UI thread.
        let end = min(query.resultCount, cursor + 512)
        guard cursor <= end else { return }
        for index in cursor..<end {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
                  FileSearchResult.isVisibleFile(path: path),
                  paths.insert(path).inserted else { continue }
            collected.append(FileSearchResult(name: name, path: path))
        }
        // Early progress can have zero results; keep matching cached rows until it fills.
        if !collected.isEmpty || !query.isGathering {
            let hasMore = end < query.resultCount
            publishFiltered(collected, text: text, generation: generation,
                            finished: finished || !query.isGathering, accumulated: accumulated,
                            more: hasMore ? { [weak self, weak query] visible in
                                guard let self, let query, self.query === query else { return }
                                self.collect(query, text: text, finished: finished, cursor: end, accumulated: visible)
                            } : nil)
        }
    }

    private func publishFiltered(_ candidates: [FileSearchResult], text: String, generation: Int, finished: Bool, accumulated: [FileSearchResult] = [], more: (([FileSearchResult]) -> Void)? = nil) {
        filterRequest?.cancel()
        let request = FileFilterRequest()
        filterRequest = request
        let exclusions = exclusions
        filterQueue.async { [weak self] in
            guard !request.isCancelled else { return }
            let visible = exclusions.filter(candidates, shouldCancel: { request.isCancelled })
            guard !request.isCancelled else { return }
            var seen = Set<String>()
            let combined = (accumulated + visible).filter { seen.insert($0.id).inserted }
            let ranked = Array(FileSearchResult.ranked(combined, for: text).prefix(40))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, self.filterRequest === request,
                      !request.isCancelled else { return }
                self.results = ranked
                self.cache.store(ranked, for: text)
                if let more, ranked.count < 40 {
                    // Keep reading in bounded slices so ignored matches cannot fill the result budget.
                    more(ranked)
                } else if finished { self.isSearching = false }
            }
        }
    }

    deinit {
        filterRequest?.cancel()
        debounceTask?.cancel()
        query?.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
