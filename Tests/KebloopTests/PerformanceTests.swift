import AppKit
import Darwin
import XCTest
@testable import Kebloop

/// Opt in with KEBLOOP_PROFILE=1; synthetic data never reads the general clipboard.
@MainActor
final class PerformanceTests: XCTestCase {
    func testLauncherProfile() async throws {
        guard ProcessInfo.processInfo.environment["KEBLOOP_PROFILE"] == "1" else {
            throw XCTSkip("Set KEBLOOP_PROFILE=1 to run the local performance profile")
        }
        _ = NSApplication.shared
        let suite = "KebloopProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "clipboardHistoryEnabled")
        let pasteboard = NSPasteboard(name: .init(suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let index = ApplicationIndex()
        let links = QuicklinkStore(defaults: defaults)
        let clipboard = ClipboardHistoryStore(defaults: defaults, pasteboard: pasteboard,
                                               storageURL: directory.appendingPathComponent("history.json"))
        let launcher = LauncherPanelController(index: index, quicklinks: links, clipboard: clipboard,
            aliases: AppAliasStore(defaults: defaults), ai: AIHandoffService(defaults: defaults, pasteboard: pasteboard),
            personalization: PersonalizationStore(defaults: defaults), appleShortcuts: AppleShortcutsService(defaults: defaults))
        launcher.show()
        let firstShow = (ProcessInfo.processInfo.systemUptime - start) * 1000
        for _ in 0..<300 {
            if !index.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let indexReady = (ProcessInfo.processInfo.systemUptime - start) * 1000
        // Let icon loading and initial AppKit layout settle before warm measurements.
        try await Task.sleep(for: .seconds(2))
        launcher.setQuery("")
        let content = try XCTUnwrap(NSApp.windows.first { $0.isVisible }?.contentView)
        let stack = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSStackView }
            .first { $0.arrangedSubviews.first is NSButton })
        let originalRows = stack.arrangedSubviews
        launcher.moveSelection(1)
        XCTAssertEqual(stack.arrangedSubviews.map(ObjectIdentifier.init), originalRows.map(ObjectIdentifier.init))
        XCTAssertEqual(originalRows[0].subviews.compactMap { $0 as? NSTextField }.last?.stringValue, "")
        XCTAssertEqual(originalRows[1].subviews.compactMap { $0 as? NSTextField }.last?.stringValue, "↵")
        launcher.moveSelection(-1)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpuStart = cpuSeconds(usage)
        let workloadStart = ProcessInfo.processInfo.systemUptime
        let queries = ["s", "sa", "saf", "safari", "term", "code", "settings", "12*34", ""]
        var queryTimes: [Double] = []
        var navigationTimes: [Double] = []
        for _ in 0..<20 {
            for query in queries {
                let tick = ProcessInfo.processInfo.systemUptime
                launcher.setQuery(query)
                NSApp.windows.first { $0.isVisible }?.contentView?.layoutSubtreeIfNeeded()
                queryTimes.append((ProcessInfo.processInfo.systemUptime - tick) * 1000)
            }
            for step in 0..<20 {
                let tick = ProcessInfo.processInfo.systemUptime
                launcher.moveSelection(step % 2 == 0 ? 1 : -1)
                navigationTimes.append((ProcessInfo.processInfo.systemUptime - tick) * 1000)
            }
            await Task.yield()
        }
        getrusage(RUSAGE_SELF, &usage)
        let workloadCPU = cpuSeconds(usage) - cpuStart
        let workloadWall = ProcessInfo.processInfo.systemUptime - workloadStart
        let peakRSS = usage.ru_maxrss
        launcher.dismiss(restoreFocus: false)
        try await Task.sleep(for: .seconds(1))
        getrusage(RUSAGE_SELF, &usage)
        let idleStart = cpuSeconds(usage)
        try await Task.sleep(for: .seconds(5))
        getrusage(RUSAGE_SELF, &usage)
        let report: [String: Double] = [
            "first_show_ms": firstShow, "index_ready_ms": indexReady,
            "application_count": Double(index.applications.count),
            "query_p50_ms": percentile(queryTimes, 0.5), "query_p95_ms": percentile(queryTimes, 0.95),
            "navigation_p50_ms": percentile(navigationTimes, 0.5),
            "navigation_p95_ms": percentile(navigationTimes, 0.95),
            "workload_cpu_seconds": workloadCPU, "workload_wall_seconds": workloadWall,
            "peak_rss_mib": Double(peakRSS) / 1_048_576,
            "idle_cpu_percent": (cpuSeconds(usage) - idleStart) / 5 * 100
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("KEBLOOP_PROFILE \(String(decoding: data, as: UTF8.self))")
        XCTAssertFalse(index.applications.isEmpty)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func cpuSeconds(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func percentile(_ samples: [Double], _ percentile: Double) -> Double {
        samples.sorted()[min(samples.count - 1, Int(Double(samples.count - 1) * percentile))]
    }
}
