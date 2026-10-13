import AppKit
import XCTest
@testable import Kebloop

final class PasteServiceTests: XCTestCase {
    @MainActor func testPermissionAndSecureInputKeepCopyWithoutPostingKeys() {
        var posted = false
        let denied = PasteService(trusted: { false }, secureInput: { false }, postPaste: { posted = true; return true })
        denied.paste(targetPID: 42, activate: { XCTFail("Must not activate without permission"); return true }) { XCTAssertEqual($0, .permission) }
        let secure = PasteService(trusted: { true }, secureInput: { true }, postPaste: { posted = true; return true })
        secure.paste(targetPID: 42, activate: { XCTFail("Must not activate during secure input"); return true }) { XCTAssertEqual($0, .secureInput) }
        XCTAssertFalse(posted)
    }

    @MainActor func testOnlyIntendedForegroundAndUnchangedClipboardReceivePaste() async {
        var posted = 0
        let service = PasteService(trusted: { true }, secureInput: { false }, frontmostPID: { 42 }, clipboardRevision: { 7 }, postPaste: { posted += 1; return true })
        let completed = expectation(description: "target receives paste")
        service.paste(targetPID: 42, activate: { true }) { error in XCTAssertNil(error); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(posted, 1)
    }

    @MainActor func testChangedClipboardOrForegroundCancelInsertion() async {
        for clipboardChanged in [false, true] {
            var revision = 1
            var posted = false
            let service = PasteService(trusted: { true }, secureInput: { false }, frontmostPID: { clipboardChanged ? 42 : 43 }, clipboardRevision: { revision }, postPaste: { posted = true; return true })
            let completed = expectation(description: "cancelled")
            service.paste(targetPID: 42, activate: { true }) { error in
                XCTAssertEqual(error, clipboardChanged ? .clipboardChanged : .focusChanged); completed.fulfill()
            }
            if clipboardChanged { revision += 1 }
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertFalse(posted)
        }
    }

    @MainActor func testInvalidTargetCancelsPreviouslyQueuedPaste() async {
        var posted = false
        let service = PasteService(trusted: { true }, secureInput: { false }, frontmostPID: { 42 }, postPaste: { posted = true; return true })
        service.paste(targetPID: 42, activate: { true }) { _ in XCTFail("Replaced paste must not finish") }
        service.paste(into: nil) { XCTAssertEqual($0, .noTarget) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(posted)
    }

    @MainActor func testReopeningLauncherCancelsPendingPaste() async {
        var posted = false
        let service = PasteService(trusted: { true }, secureInput: { false }, frontmostPID: { 42 }, postPaste: { posted = true; return true })
        service.paste(targetPID: 42, activate: { true }) { _ in XCTFail("Cancelled paste must not finish") }
        service.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(posted)
    }
}
