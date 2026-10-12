import Foundation
import XCTest
@testable import Kebloop

final class ApplicationIndexTests: XCTestCase {
    @MainActor
    func testRequestedNativeIconRemainsAvailableInCache() async throws {
        let index = ApplicationIndex()
        let app = IndexedApplication(name: "System Settings", path: "/System/Applications/System Settings.app")
        _ = index.icon(for: app)
        try await Task.sleep(for: .milliseconds(100))
        let cached = try XCTUnwrap(index.icon(for: app), "A loaded native icon must not be immediately evicted")
        XCTAssertTrue(index.icon(for: app) === cached)
    }

    func testRefreshDueRequiresMissingOrExpiredCompletionTimestamp() {
        let now = Date()
        let interval: TimeInterval = 5 * 60

        XCTAssertTrue(ApplicationIndex.isRefreshDue(lastCompletedAt: nil, now: now, interval: interval))
        XCTAssertFalse(ApplicationIndex.isRefreshDue(
            lastCompletedAt: now.addingTimeInterval(-interval + 1),
            now: now,
            interval: interval
        ))
        XCTAssertTrue(ApplicationIndex.isRefreshDue(
            lastCompletedAt: now.addingTimeInterval(-interval),
            now: now,
            interval: interval
        ))
    }

    func testAdditionalApplicationBundleOutsideRootsIsIncluded() throws {
        try withDirectory { root in
            let scannedFolder = root.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: scannedFolder, withIntermediateDirectories: true)
            let finder = root.appendingPathComponent("CoreServices/Finder.app", isDirectory: true)
            try makeApplicationBundle(at: finder, name: "Finder")

            let applications = ApplicationIndex.scanApplications(roots: [scannedFolder], additionalApplications: [finder])

            XCTAssertEqual(applications.map(\.name), ["Finder"])
            XCTAssertEqual(applications.first?.path, finder.standardizedFileURL.path)
        }
    }

    func testCoreServicesApplicationsFolderDoesNotIncludeInternalOrBackgroundHelpers() throws {
        try withDirectory { root in
            let coreServices = root.appendingPathComponent("CoreServices", isDirectory: true)
            let userFacingApplications = coreServices.appendingPathComponent("Applications", isDirectory: true)
            let internalHelper = coreServices.appendingPathComponent("Internal/Helper.app", isDirectory: true)
            let backgroundAgent = userFacingApplications.appendingPathComponent("Background Helper.app", isDirectory: true)
            let utility = userFacingApplications.appendingPathComponent("Archive Utility.app", isDirectory: true)
            try makeApplicationBundle(at: internalHelper, name: "Internal Helper")
            try makeApplicationBundle(at: backgroundAgent, name: "Background Helper", backgroundOnly: true)
            try makeApplicationBundle(at: utility, name: "Archive Utility")

            let applications = ApplicationIndex.scanApplications(
                roots: [userFacingApplications],
                additionalApplications: []
            )

            XCTAssertEqual(applications.map(\.name), ["Archive Utility"])
            XCTAssertFalse(applications.contains { $0.path == internalHelper.path })
            XCTAssertFalse(applications.contains { $0.path == backgroundAgent.path })
        }
    }

    func testNestedBundlesAreSkippedAndAdditionalPathsAreDeduplicated() throws {
        try withDirectory { root in
            let applicationsFolder = root.appendingPathComponent("Applications", isDirectory: true)
            let parent = applicationsFolder.appendingPathComponent("Parent.app", isDirectory: true)
            let nestedHelper = parent.appendingPathComponent("Contents/Helpers/Helper.app", isDirectory: true)
            let standalone = applicationsFolder.appendingPathComponent("Standalone.app", isDirectory: true)
            try makeApplicationBundle(at: parent, name: "Parent")
            try makeApplicationBundle(at: nestedHelper, name: "Nested Helper")
            try makeApplicationBundle(at: standalone, name: "Standalone")

            let applications = ApplicationIndex.scanApplications(
                roots: [applicationsFolder],
                additionalApplications: [parent, standalone]
            )

            XCTAssertEqual(Set(applications.map(\.path)), [parent.standardizedFileURL.path, standalone.standardizedFileURL.path])
            XCTAssertEqual(applications.count, 2)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kebloop-application-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeApplicationBundle(
        at url: URL,
        name: String,
        backgroundOnly: Bool = false
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleExecutable": name.replacingOccurrences(of: " ", with: ""),
            "CFBundleIdentifier": "test.kebloop.\(UUID().uuidString)",
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL"
        ]
        if backgroundOnly {
            info["LSBackgroundOnly"] = true
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
