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
    func testVerticalHalvesAndQuartersTileOddVisibleFrame() {
        let screen = CGRect(x: -801, y: -101, width: 801, height: 701)
        let top = WindowManagementService.arrangedFrame(.topHalf, original: .zero, screen: screen)
        let bottom = WindowManagementService.arrangedFrame(.bottomHalf, original: .zero, screen: screen)
        XCTAssertEqual(top.minY, screen.minY)
        XCTAssertEqual(top.maxY, bottom.minY)
        XCTAssertEqual(bottom.maxY, screen.maxY)

        let topLeft = WindowManagementService.arrangedFrame(.topLeftQuarter, original: .zero, screen: screen)
        let topRight = WindowManagementService.arrangedFrame(.topRightQuarter, original: .zero, screen: screen)
        let bottomLeft = WindowManagementService.arrangedFrame(.bottomLeftQuarter, original: .zero, screen: screen)
        let bottomRight = WindowManagementService.arrangedFrame(.bottomRightQuarter, original: .zero, screen: screen)
        XCTAssertEqual(topLeft.maxX, topRight.minX)
        XCTAssertEqual(bottomLeft.maxX, bottomRight.minX)
        XCTAssertEqual(topLeft.maxY, bottomLeft.minY)
        XCTAssertEqual(topRight.maxY, bottomRight.minY)
        XCTAssertEqual(topLeft.minX, screen.minX)
        XCTAssertEqual(topRight.maxX, screen.maxX)
        XCTAssertEqual(bottomLeft.minY, top.minY + screen.height / 2)
        XCTAssertEqual(bottomRight.maxY, screen.maxY)
    }
    @MainActor
    func testThirdsAndTwoThirdLayoutsShareExactBoundaries() {
        let screen = CGRect(x: 15, y: 30, width: 1001, height: 700)
        let left = WindowManagementService.arrangedFrame(.leftThird, original: .zero, screen: screen)
        let center = WindowManagementService.arrangedFrame(.centerThird, original: .zero, screen: screen)
        let right = WindowManagementService.arrangedFrame(.rightThird, original: .zero, screen: screen)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(left.maxX, center.minX)
        XCTAssertEqual(center.maxX, right.minX)
        XCTAssertEqual(right.maxX, screen.maxX)

        let leftTwoThirds = WindowManagementService.arrangedFrame(.leftTwoThirds, original: .zero, screen: screen)
        let rightTwoThirds = WindowManagementService.arrangedFrame(.rightTwoThirds, original: .zero, screen: screen)
        XCTAssertEqual(leftTwoThirds.minX, screen.minX)
        XCTAssertEqual(leftTwoThirds.maxX, right.minX)
        XCTAssertEqual(rightTwoThirds.minX, left.minX + screen.width / 3)
        XCTAssertEqual(rightTwoThirds.maxX, screen.maxX)
        XCTAssertEqual(leftTwoThirds.height, screen.height)
        XCTAssertEqual(rightTwoThirds.height, screen.height)
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
