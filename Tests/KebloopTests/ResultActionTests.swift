import XCTest
@testable import Kebloop

final class ResultActionTests: XCTestCase {
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
