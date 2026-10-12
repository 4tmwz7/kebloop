import AppKit
import Carbon
import XCTest
@testable import Kebloop

@MainActor final class UserCommandShortcutTests: XCTestCase {
    func testNonUSCharactersKeepTheirHardwareCodeAndReadableLabel() throws {
        let recorder = ShortcutCaptureView()
        var recordedCode: UInt32?, recordedModifiers: UInt32?, recordedLabel: String?
        recorder.record = { recordedCode = $0; recordedModifiers = $1; recordedLabel = $2 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .capsLock], timestamp: 0, windowNumber: 0, context: nil, characters: "ł", charactersIgnoringModifiers: "ł", isARepeat: false, keyCode: 37))
        recorder.keyDown(with: event)
        XCTAssertEqual(recordedCode, 37)
        XCTAssertEqual(recordedModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(recordedLabel, "⌥⌘ Ł")
        var cancelled = false
        recorder.cancel = { cancelled = true }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Escape)))
        recorder.keyDown(with: escape)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(recordedLabel, "⌥⌘ Ł")
    }

    func testSnippetScriptAndExtensionShortcutPersistenceDisableAndRemoval() throws {
        let suite = "UserCommandShortcutTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotkey = HotkeyService(), store = CommandShortcutStore(hotkey: hotkey, defaults: defaults)
        defer { store.unregisterAll() }
        let key = UInt32(kVK_F19), modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        for id in ["snippet:test", "script:test", "extension:test"] {
            XCTAssertTrue(store.assign(commandID: id, keyCode: key, modifiers: modifiers, label: "Synthetic test shortcut"))
            store.reload()
            XCTAssertEqual(store.bindings.map(\.id), [id])
            XCTAssertTrue(hotkey.conflictsWithBinding(id: "other", keyCode: key, modifiers: modifiers))
            store.isEnabled = { _ in false }; store.resume()
            XCTAssertFalse(hotkey.conflictsWithBinding(id: "other", keyCode: key, modifiers: modifiers))
            XCTAssertEqual(store.bindings.map(\.id), [id])
            store.isEnabled = { _ in true }; store.resume()
            XCTAssertTrue(hotkey.conflictsWithBinding(id: "other", keyCode: key, modifiers: modifiers))
            store.remove(id: id); store.reload()
            XCTAssertTrue(store.bindings.isEmpty)
            XCTAssertFalse(hotkey.conflictsWithBinding(id: "other", keyCode: key, modifiers: modifiers))
        }
    }
}
