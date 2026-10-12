import Foundation
@main struct Benchmark {
    static func main() {
        let paths = (0..<512).map { "/Users/person/Documents/project/subfolder/report-\($0).txt" }
        var visible = 0
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 {
            for path in paths { if FileSearchResult.isVisibleFile(path: path) { visible += 1 } }
        }
        print("visible=\(visible) duration_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
    }
}
