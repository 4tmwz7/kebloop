import XCTest
import CoreServices
@testable import Kebloop

final class NativeControlTests: XCTestCase {
    func testDisruptiveSystemEventsUseConfirmation() {
        XCTAssertEqual(SystemActionService.makeConfirmationEvent(.restart).eventID, kAEShowRestartDialog)
        XCTAssertEqual(SystemActionService.makeConfirmationEvent(.logOut).eventID, kAELogOut)
        XCTAssertNotEqual(SystemActionService.makeConfirmationEvent(.logOut).eventID, kAEReallyLogOut)
    }
    @MainActor
    func testScreenCoordinateConversionIncludesDisplaysAboveAndLeft() {
        XCTAssertEqual(WindowManagementService.accessibilityRect(CGRect(x: -1200, y: 900, width: 1200, height: 800), primaryHeight: 900), CGRect(x: -1200, y: -800, width: 1200, height: 800))
    }
    @MainActor
    func testHalvesUseVisibleFrameAndCoverOddWidth() {
        let screen = CGRect(x: -801, y: 25, width: 801, height: 700)
        let left = WindowManagementService.arrangedFrame(.leftHalf, original: .zero, screen: screen)
        let right = WindowManagementService.arrangedFrame(.rightHalf, original: .zero, screen: screen)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(right.height, 700)
    }
    @MainActor
    func testMovePreservesSizeAndClampsToSmallerDisplay() {
        let source = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let target = CGRect(x: -800, y: -600, width: 800, height: 600)
        let moved = WindowManagementService.move(CGRect(x: 1200, y: 800, width: 1000, height: 900), from: source, to: target)
        XCTAssertEqual(moved, target)
    }
    @MainActor
    func testSelectsScreenWithGreatestIntersectionAndCentersOversizeWindow() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(WindowManagementService.screenIndex(for: CGRect(x: 900, y: 100, width: 500, height: 400), screens: screens), 1)
        XCTAssertEqual(WindowManagementService.arrangedFrame(.center, original: CGRect(x: 0, y: 0, width: 1500, height: 900), screen: screens[1]), screens[1])
    }
}
