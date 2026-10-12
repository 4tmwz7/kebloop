import AppKit
import XCTest
@testable import Kebloop

@MainActor
final class ActionMenuTests: XCTestCase {
    private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testCommandKIgnoresDeviceAndLockFlags() throws {
        XCTAssertTrue(LauncherKeyboard.isActionShortcut(try key(40, characters: "k", modifiers: [.command, .capsLock, .function, .init(rawValue: 0x08)])))
        XCTAssertFalse(LauncherKeyboard.isActionShortcut(try key(40, characters: "k", modifiers: [.command, .shift])))
        XCTAssertFalse(LauncherKeyboard.isActionShortcut(try key(40, characters: "k", modifiers: [.control])))
    }

    func testCustomMenuNavigationExecutionAndEscapePreserveSelection() throws {
        _ = NSApplication.shared
        let parent = NSPanel(contentRect: NSRect(x: 50, y: 50, width: 560, height: 200),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let menu = ActionMenuController()
        let items = [ActionMenuItem(action: .open, title: "Open"), ActionMenuItem(action: .copyPath, title: "Copy Path")]
        var chosen: ResultAction?
        var restoreFocus = false
        menu.show(items: items, title: "Example", parent: parent, opaque: true,
                  onChoose: { chosen = $0 }, onClose: { restoreFocus = $0 })
        XCTAssertTrue(menu.isVisible)
        XCTAssertTrue(menu.handleKey(try key(125, characters: "")))
        XCTAssertEqual(menu.selectedIndex, 1)
        XCTAssertTrue(menu.handleKey(try key(36, characters: "\r")))
        XCTAssertEqual(chosen, .copyPath)
        XCTAssertFalse(menu.isVisible)
        XCTAssertTrue(restoreFocus)
        chosen = nil
        menu.show(items: items, title: "Example", parent: parent, opaque: true,
                  onChoose: { chosen = $0 }, onClose: { restoreFocus = $0 })
        XCTAssertTrue(menu.handleKey(try key(53, characters: "")))
        XCTAssertNil(chosen)
        XCTAssertFalse(menu.isVisible)
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
        parent.orderOut(nil)
    }
}
