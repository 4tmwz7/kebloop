import AppKit
import ApplicationServices
import XCTest
@testable import Kebloop

@MainActor
final class SiriPromptSenderTests: XCTestCase {
    func testIdentifiesOnlyEnabledSiriComposer() {
        XCTAssertTrue(descriptor(identifier: "promptViewTextField").isPrompt)
        XCTAssertTrue(descriptor(placeholder: "Ask Siri").isPrompt)
        XCTAssertFalse(descriptor(identifier: "searchField", placeholder: "Search").isPrompt)
        XCTAssertFalse(descriptor(identifier: "promptViewTextField", enabled: false).isPrompt)
        XCTAssertFalse(descriptor(role: kAXStaticTextRole, identifier: "promptViewTextField").isPrompt)
    }

    func testNewConversationRequiresExactEnabledButton() {
        XCTAssertTrue(descriptor(role: kAXButtonRole, identifier: "newChatButton").isNewConversation)
        XCTAssertFalse(descriptor(role: kAXButtonRole, identifier: "newChatButton", enabled: false).isNewConversation)
        XCTAssertFalse(descriptor(role: kAXTextFieldRole, identifier: "newChatButton").isNewConversation)
    }

    func testPermissionFailurePrecedesAnyAppInteraction() {
        let sender = SiriPromptSender(permissionGranted: { false })
        var result: String?
        sender.submit("Hello", application: .current) { result = $0 }
        XCTAssertTrue(result?.contains("Privacy & Security → Accessibility") == true)
    }

    func testEmptyPromptRejectedBeforeAppInteraction() {
        let sender = SiriPromptSender(permissionGranted: { true })
        var result: String?
        sender.submit(" \n ", application: .current) { result = $0 }
        XCTAssertEqual(result, "Enter a prompt first.")
    }

    func testNonSiriApplicationCannotReceivePrompt() {
        let sender = SiriPromptSender(permissionGranted: { true })
        var result: String?
        sender.submit("Hello", application: .current) { result = $0 }
        XCTAssertEqual(result, "Kebloop couldn't find the Siri application.")
    }

    private func descriptor(role: String = kAXTextFieldRole, identifier: String = "", placeholder: String = "", enabled: Bool = true) -> SiriElementDescriptor {
        SiriElementDescriptor(role: role, identifier: identifier, placeholder: placeholder, enabled: enabled)
    }
}
