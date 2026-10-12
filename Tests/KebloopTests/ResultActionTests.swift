import XCTest
@testable import Kebloop

final class ResultActionTests: XCTestCase {
    func testClipboardActionsIncludeRemoveForPinnedAndUnpinnedItems() {
        XCTAssertEqual(ResultAction.available(kind: .clipboard), [.open, .pin, .removeClipboardItem])
        XCTAssertEqual(ResultAction.available(kind: .clipboard, pinned: true), [.open, .unpin, .removeClipboardItem])
        for kind in [ResultAction.Kind.file, .application, .quicklink, .command, .appleShortcut, .other] {
            XCTAssertFalse(ResultAction.available(kind: kind).contains(.removeClipboardItem))
        }
    }
    func testFileAndApplicationActionsKeepOpenPrimary() {
        XCTAssertEqual(ResultAction.available(kind: .file), [.open, .reveal, .copyPath, .openWith, .pin])
        XCTAssertEqual(ResultAction.available(kind: .application), [.open, .reveal, .copyPath, .pin])
    }
    func testEditableQuicklinksAndSupportedPins() {
        XCTAssertEqual(ResultAction.available(kind: .quicklink, pinned: true), [.open, .editQuicklink, .unpin])
        XCTAssertEqual(ResultAction.available(kind: .command), [.open, .pin])
        XCTAssertEqual(ResultAction.available(kind: .other, pinned: true), [.open])
        XCTAssertEqual(ResultAction.available(kind: .appleShortcut), [.open, .runWithInput])
    }
}
