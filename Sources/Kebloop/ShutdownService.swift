import AppKit
import CoreServices

enum ShutdownService {
    private static let loginWindowBundleIdentifier = "com.apple.loginwindow"
    private static let sendOptions: NSAppleEventDescriptor.SendOptions = [.noReply, .canInteract]

    static func requestConfirmation() throws {
        try requestConfirmation(using: send)
    }

    static func requestConfirmation(using sender: (NSAppleEventDescriptor, NSAppleEventDescriptor.SendOptions) throws -> Void) throws {
        try sender(makeEvent(), sendOptions)
    }

    static func makeEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: kCoreEventClass,
            eventID: kAEShowShutdownDialog,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: loginWindowBundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private static func send(_ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions) throws {
        _ = try event.sendEvent(options: options, timeout: 5)
    }
}
