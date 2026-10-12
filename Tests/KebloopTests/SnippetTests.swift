import AppKit
import XCTest
@testable import Kebloop

final class SnippetTests: XCTestCase {
    @MainActor func testSnippetDialogsPreviewCopyCancellationAndInsertionFallback() throws {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init("SnippetDialogs.\(UUID())")); defer { board.releaseGlobally() }
        func reset() { board.clearContents(); board.setString("unchanged clipboard", forType: .string) }
        let snippet = Snippet(name: "Greeting", template: "Hello {name}, {message}")
        reset()
        var dialogs = 0
        let copied = SnippetPresenter.prepare(snippet, pasteboard: board, runAlert: { alert in
            dialogs += 1
            if let field = alert.accessoryView as? NSTextField { field.stringValue = dialogs == 1 ? "Łukasz" : "{name} stays literal" }
            if let scroll = alert.accessoryView as? NSScrollView {
                XCTAssertEqual((scroll.documentView as? NSTextView)?.string, "Hello Łukasz, {name} stays literal")
            }
            return .alertFirstButtonReturn
        }, isTrusted: { XCTFail("Copy must not request Accessibility"); return false })
        XCTAssertEqual(dialogs, 3); XCTAssertEqual(copied?.insert, false)
        XCTAssertEqual(board.string(forType: .string), "Hello Łukasz, {name} stays literal")
        for cancelStep in [1, 2, 3] {
            reset(); dialogs = 0
            XCTAssertNil(SnippetPresenter.prepare(snippet, pasteboard: board, runAlert: { alert in
                dialogs += 1
                (alert.accessoryView as? NSTextField)?.stringValue = "value"
                if dialogs == cancelStep { return cancelStep == 3 ? .alertThirdButtonReturn : .alertSecondButtonReturn }
                return .alertFirstButtonReturn
            }))
            XCTAssertEqual(board.string(forType: .string), "unchanged clipboard")
        }
        let plain = Snippet(name: "Plain", template: "Copied fallback")
        reset(); dialogs = 0
        let fallback = SnippetPresenter.prepare(plain, pasteboard: board, runAlert: { alert in
            dialogs += 1
            if dialogs == 2 { XCTAssertEqual(alert.messageText, L("Text copied")); return .alertFirstButtonReturn }
            return .alertSecondButtonReturn
        }, isTrusted: { false })
        XCTAssertEqual(dialogs, 2); XCTAssertEqual(fallback?.insert, false)
        XCTAssertEqual(board.string(forType: .string), "Copied fallback")
        let insert = SnippetPresenter.prepare(plain, pasteboard: board, runAlert: { _ in .alertSecondButtonReturn }, isTrusted: { true })
        XCTAssertEqual(insert?.insert, true)
        reset()
        XCTAssertNil(SnippetPresenter.prepare(plain, pasteboard: board, runAlert: { _ in .abort }))
        XCTAssertEqual(board.string(forType: .string), "unchanged clipboard")
    }

    @MainActor func testSnippetEditingValidationMergeReplaceAndProfiles() throws {
        let suite = "SnippetWorkflow.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snippets = SnippetStore(defaults: defaults)
        try snippets.save(name: "Work", template: "Work {name}")
        let workID = snippets.snippets[0].id
        try snippets.save(id: workID, name: "Edited", template: "Edited {name}")
        XCTAssertEqual(snippets.snippets.count, 1); XCTAssertEqual(snippets.snippets[0].name, "Edited")
        for (name, text) in [(" ", "valid"), ("Valid", ""), ("Valid", String(repeating: "x", count: 100_001))] {
            XCTAssertThrowsError(try snippets.save(name: name, template: text))
        }
        let store = ConfigurationStore(defaults: defaults, reload: { snippets.reload() })
        let workProfile = store.activeProfileID
        let personalProfile = try store.createProfile(name: "Personal snippets")
        try store.switchProfile(id: personalProfile)
        snippets.remove(id: workID); try snippets.save(name: "Personal", template: "Personal text")
        let personal = snippets.snippets
        try store.switchProfile(id: workProfile)
        XCTAssertEqual(snippets.snippets.map(\.id), [workID])
        try store.switchProfile(id: personalProfile)
        XCTAssertEqual(snippets.snippets, personal)
        let personalExport = try store.exportData()
        snippets.remove(id: personal[0].id); try snippets.save(name: "Other", template: "Other text")
        try store.apply(preview: store.preview(data: personalExport), mode: .merge)
        XCTAssertEqual(Set(snippets.snippets.map(\.name)), ["Other", "Personal"])
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("SnippetBackup.\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: backup) }
        try store.apply(preview: store.preview(data: personalExport), mode: .replace, backupURL: backup)
        XCTAssertEqual(snippets.snippets, personal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPlaceholderOrderAndLiteralValues() throws {
        let snippet = Snippet(name: "Hello", template: "Hi {name}, {name}! {message}")
        XCTAssertEqual(snippet.placeholders, ["name", "message"])
        XCTAssertEqual(try snippet.render(values: ["name": "{message}", "message": "Zażółć 😀"]), "Hi {message}, {message}! Zażółć 😀")
        XCTAssertThrowsError(try snippet.render(values: ["name": "A"]))
    }
    @MainActor func testPersistenceConfigurationAndLegacyMigration() throws {
        let suite = "SnippetTests.\(UUID().uuidString)"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snippets = SnippetStore(defaults: defaults)
        try snippets.save(name: "Greeting", template: "Hello {name}")
        XCTAssertEqual(SnippetStore(defaults: defaults).snippets, snippets.snippets)
        let configuration = ConfigurationStore(defaults: defaults)
        let data = try configuration.exportData()
        XCTAssertEqual(try configuration.preview(data: data).configuration.settings.snippets, snippets.snippets)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var settings = try XCTUnwrap(json["settings"] as? [String: Any]); settings.removeValue(forKey: "snippets"); settings.removeValue(forKey: "scripts"); settings.removeValue(forKey: "extensions"); json["settings"] = settings
        _ = try configuration.preview(data: JSONSerialization.data(withJSONObject: json))
        snippets.remove(id: snippets.snippets[0].id)
        XCTAssertTrue(SnippetStore(defaults: defaults).snippets.isEmpty)
    }
}
