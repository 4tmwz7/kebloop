import Foundation
import XCTest
@testable import Kebloop

final class FileSearchExclusionTests: XCTestCase {
    func testTemporaryFilesAndDirectories() {
        let excluded = ["/tmp/report.txt", "/private/tmp/report.txt", "/var/tmp/report.txt", "/private/var/tmp/report.txt",
                        NSTemporaryDirectory() + "report.txt", "/Users/person/project/TEMP/report.txt", "/Users/person/tmp/report.txt",
                        "/Users/person/report.TMP", "/Users/person/report.temp", "/Users/person/report.swp", "/Users/person/report.swo",
                        "/Users/person/report.bak", "/Users/person/report.orig", "/Users/person/report.rej", "/Users/person/report.txt~",
                        "/Users/person/~$report.docx", "/Users/person/video.part", "/Users/person/video.partial",
                        "/Users/person/video.crdownload", "/Users/person/video.download/content"]
        for path in excluded { XCTAssertTrue(FileSearchExclusions.isTemporary(path: path), path) }
        for path in ["/Users/person/template.txt", "/Users/person/tempest/readme", "/Users/person/Backup/report.txt", "/Users/person/temp"] {
            XCTAssertFalse(FileSearchExclusions.isTemporary(path: path), path)
        }
    }

    func testGitRulesRespectNestedNegationsAndTrackedFiles() throws {
        try withDirectory { root in
            try git(["init", "-q"], at: root)
            try write("*.log\n!keep.log\nignored/\n", to: root.appendingPathComponent(".gitignore"))
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try write("!nested.log\n", to: nested.appendingPathComponent(".gitignore"))
            try write("tracked", to: root.appendingPathComponent("tracked.log"))
            try git(["add", "-f", "tracked.log"], at: root)
            let names = ["drop.log", "keep.log", "tracked.log", "nested/nested.log", "nested/drop.log", "ignored/child.txt", "ordinary.txt"]
            XCTAssertEqual(filtered(names, root: root), ["keep.log", "tracked.log", "nested/nested.log", "ordinary.txt"])
        }
    }

    func testInfoAndConfiguredGlobalExcludesAndRuleRefresh() throws {
        try withDirectory { root in
            try git(["init", "-q"], at: root)
            try write("local-secret.txt\n", to: root.appendingPathComponent(".git/info/exclude"))
            let globalRules = root.appendingPathComponent("global-ignore")
            try write("global-secret.txt\n", to: globalRules)
            try git(["config", "core.excludesFile", globalRules.path], at: root)
            try write("first.txt\n", to: root.appendingPathComponent(".gitignore"))
            let exclusions = FileSearchExclusions()
            let names = ["local-secret.txt", "global-secret.txt", "first.txt", "second.txt"]
            XCTAssertEqual(filtered(names, root: root, exclusions: exclusions), ["second.txt"])
            try write("second.txt\n", to: root.appendingPathComponent(".gitignore"))
            XCTAssertEqual(filtered(names, root: root, exclusions: exclusions), ["first.txt"])
        }
    }

    func testSpacesNewlinesAndBatchesUseNullDelimitedPaths() throws {
        try withDirectory { root in
            try git(["init", "-q"], at: root)
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            let ignored = (0..<520).map { "\(String(repeating: "x", count: 150))-\($0).ignored" }
            let names = ["has space.ignored", "has\nnewline.ignored", "has space.txt", "has\nnewline.txt"] + ignored
            XCTAssertEqual(filtered(names, root: root), ["has space.txt", "has\nnewline.txt"])
        }
    }

    func testWorktreeGitFileAndNestedRepository() throws {
        try withDirectory { root in
            let repository = root.appendingPathComponent("repository")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try git(["init", "-q"], at: repository)
            try git(["-c", "user.name=Kebloop Tests", "-c", "user.email=tests@example.invalid", "commit", "--allow-empty", "-qm", "initial"], at: repository)
            let worktree = root.appendingPathComponent("worktree")
            try git(["worktree", "add", "-qb", "test-worktree", worktree.path], at: repository)
            try write("*.ignored\n", to: worktree.appendingPathComponent(".gitignore"))
            XCTAssertEqual(filtered(["file.ignored", "file.txt"], root: worktree), ["file.txt"])
            let nested = worktree.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try git(["init", "-q"], at: nested)
            // The enclosing worktree's ignore rules don't apply to a separate repository.
            XCTAssertEqual(filtered(["nested/file.ignored"], root: worktree), ["nested/file.ignored"])
        }
    }

    func testOutsideRepositoryAndFailedGitPreserveFiles() throws {
        try withDirectory { root in
            try write("*.txt\n", to: root.appendingPathComponent(".gitignore"))
            XCTAssertEqual(filtered(["visible.txt"], root: root), ["visible.txt"])
            try write("gitdir: missing-repository\n", to: root.appendingPathComponent(".git"))
            XCTAssertEqual(filtered(["visible.txt"], root: root), ["visible.txt"])
        }
    }

    func testNamedTemporaryDirectoriesAndCancellation() throws {
        try withDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("temp"), withIntermediateDirectories: true)
            try write("ordinary file", to: root.appendingPathComponent("tmp"))
            XCTAssertEqual(filtered(["temp", "tmp"], root: root), ["tmp"])
            let files = [FileSearchResult(name: "visible.txt", path: root.appendingPathComponent("visible.txt").path)]
            XCTAssertTrue(FileSearchExclusions().filter(files, shouldCancel: { true }).isEmpty)
        }
    }

    private func filtered(_ names: [String], root: URL, exclusions: FileSearchExclusions = FileSearchExclusions()) -> [String] {
        let files = names.map { FileSearchResult(name: $0, path: root.appendingPathComponent($0).path) }
        return exclusions.filter(files).map(\.name)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        // System temp locations are deliberately excluded, so fixtures live in home.
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kebloop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "GitTestFixture", code: Int(process.terminationStatus)) }
    }
}
