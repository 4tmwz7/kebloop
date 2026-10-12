import XCTest
import Carbon
@testable import Kebloop

final class HotkeyTests: XCTestCase {
    @MainActor
    func testCarbonEventsRouteToLauncherAndDistinctAppActions() async throws {
        let service = HotkeyService()
        let launcher = expectation(description: "Launcher callback")
        let first = expectation(description: "First app callback")
        let second = expectation(description: "Second app callback")
        service.onPress = { launcher.fulfill() }
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        XCTAssertTrue(service.registerBinding(id: "first", keyCode: UInt32(kVK_F19), modifiers: modifiers) { first.fulfill() })
        XCTAssertTrue(service.registerBinding(id: "second", keyCode: UInt32(kVK_F20), modifiers: modifiers) { second.fulfill() })
        try sendHotkey(id: 1)
        try sendHotkey(id: 2)
        try sendHotkey(id: 3)
        await fulfillment(of: [launcher, first, second], timeout: 2)
        service.unregisterBinding(id: "first")
        service.unregisterBinding(id: "second")
    }

    @MainActor
    func testUnregisteredAndSuspendedEventsDoNotInvokeActions() async throws {
        let service = HotkeyService()
        let callback = expectation(description: "Removed callback must not run")
        callback.isInverted = true
        XCTAssertTrue(service.registerBinding(id: "removed", keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | controlKey | shiftKey)) { callback.fulfill() })
        service.unregisterBinding(id: "removed")
        try sendHotkey(id: 2)
        let launcher = expectation(description: "Suspended launcher must not run")
        launcher.isInverted = true
        service.onPress = { launcher.fulfill() }
        service.isSuspended = true
        try sendHotkey(id: 1)
        await fulfillment(of: [callback, launcher], timeout: 0.1)
    }

    @MainActor
    func testLauncherCombinationCannotBeAssignedToApp() {
        let service = HotkeyService()
        let shortcut = Shortcut(id: "test", label: "Test", modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        XCTAssertTrue(service.register(shortcut))
        XCTAssertTrue(service.conflictsWithLauncher(keyCode: UInt32(kVK_Space), modifiers: shortcut.modifiers))
        XCTAssertFalse(service.registerBinding(id: "conflict", keyCode: UInt32(kVK_Space), modifiers: shortcut.modifiers) {})
    }

    @MainActor
    private func sendHotkey(id: UInt32) throws {
        var createdEvent: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), EventAttributes(0), &createdEvent), noErr)
        let event = try XCTUnwrap(createdEvent)
        defer { ReleaseEvent(event) }
        var identifier = EventHotKeyID(signature: 0x4B45424C, id: id)
        XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        XCTAssertEqual(SendEventToEventTarget(event, GetApplicationEventTarget()), noErr)
    }
}
