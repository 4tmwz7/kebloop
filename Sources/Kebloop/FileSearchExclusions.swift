import Foundation

// Run on the file-search worker queue: filesystem checks and Git never block input.
final class FileSearchExclusions: Sendable {
    func filter(_ files: [FileSearchResult], shouldCancel: () -> Bool = { false }) -> [FileSearchResult] {
        guard !shouldCancel() else { return [] }
        let candidates = files.filter { file in
            guard !shouldCancel() else { return false }
            guard !Self.isTemporary(path: file.path) else { return false }
            if ["tmp", "temp"].contains(file.url.lastPathComponent.lowercased()) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return false
                }
            }
            return true
        }
        // Discovery is cached only within this snapshot, so new repositories and
        // changed ignore rules take effect on the next search refresh.
        var repositories: [String: String] = [:]
        var outsideRepositories = Set<String>()
        var grouped: [String: [String]] = [:]
        for file in candidates {
            guard !shouldCancel() else { return [] }
            if let repository = repository(containing: file.path, cache: &repositories, outside: &outsideRepositories) {
                grouped[repository, default: []].append(file.path)
            }
        }
        var ignored = Set<String>()
        for (repository, paths) in grouped {
            for offset in stride(from: 0, to: paths.count, by: 512) {
                guard !shouldCancel() else { return [] }
                ignored.formUnion(ignoredPaths(Array(paths[offset..<min(offset + 512, paths.count)]), repository: repository))
            }
        }
        return candidates.filter { !ignored.contains($0.path) }
    }

    static func isTemporary(path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let temporaryRoots = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
        if temporaryRoots.contains(where: { root in
            let root = (root as NSString).standardizingPath
            return normalized == root || normalized.hasPrefix(root + "/")
        }) { return true }
        let components = normalized.split(separator: "/").map { $0.lowercased() }
        // Only whole directory names qualify; template.txt and tempest are ordinary files.
        if components.dropLast().contains(where: { $0 == "tmp" || $0 == "temp" }) { return true }
        let suffixes = ["tmp", "temp", "swp", "swo", "bak", "orig", "rej", "part", "partial", "crdownload", "download"]
        return components.contains { component in
            component.hasPrefix("~$") || component.hasSuffix("~")
                || suffixes.contains((component as NSString).pathExtension)
        }
    }

    private func repository(containing path: String, cache: inout [String: String], outside: inout Set<String>) -> String? {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        var visited: [String] = []
        var found: String?
        while true {
            if let cached = cache[directory] { found = cached; break }
            if outside.contains(directory) { break }
            visited.append(directory)
            // Both a normal repository directory and a worktree's .git file count.
            if FileManager.default.fileExists(atPath: directory + "/.git") { found = directory; break }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || directory == "/" || parent.isEmpty { break }
            directory = parent
        }
        for directory in visited {
            if let found { cache[directory] = found } else { outside.insert(directory) }
        }
        return found
    }

    private func ignoredPaths(_ paths: [String], repository: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository, "check-ignore", "--stdin", "-z"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let data = Data((paths.joined(separator: "\0") + "\0").utf8)
        do { try process.run() } catch { return [] }
        // Drain stdout while writing stdin: long paths must not fill both pipes.
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? input.fileHandleForWriting.close(); writer.leave() }
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        writer.wait()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { return [] }
        return Set(result.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) })
    }
}
