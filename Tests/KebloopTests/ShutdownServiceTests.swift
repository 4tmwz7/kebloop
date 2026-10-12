import AppKit
import CoreServices
import XCTest
@testable import Kebloop

final class ShutdownServiceTests: XCTestCase {
    func testBuildsShowShutdownDialogEventForLoginWindow() {
        let event = ShutdownService.makeEvent()

        XCTAssertEqual(event.eventClass, kCoreEventClass)
        XCTAssertEqual(event.eventID, kAEShowShutdownDialog)
        XCTAssertNotEqual(event.eventID, kAEShutDown)

        let target = event.attributeDescriptor(forKeyword: keyAddressAttr)
        XCTAssertEqual(target?.descriptorType, typeApplicationBundleID)
        XCTAssertEqual(target.flatMap { String(data: $0.data, encoding: .utf8) }, "com.apple.loginwindow")
    }

    func testRequestUsesInteractiveNoReplyAndPropagatesSendFailure() {
        let expectedError = NSError(domain: "ShutdownServiceTests", code: 1)
        var receivedOptions: NSAppleEventDescriptor.SendOptions = []

        XCTAssertThrowsError(try ShutdownService.requestConfirmation { event, options in
            XCTAssertEqual(event.eventID, kAEShowShutdownDialog)
            receivedOptions = options
            throw expectedError
        }) { error in
            XCTAssertEqual(error as NSError, expectedError)
        }

        XCTAssertEqual(receivedOptions, [.noReply, .canInteract])
    }
}
