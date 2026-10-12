# Performance profiling

Run `./scripts/profile-app.sh` on macOS with the selected Xcode toolchain. It builds in release mode and prints a `KEBLOOP_PROFILE` JSON record, then runs an isolated file-path benchmark with `/usr/bin/time -l` resource counters. The profile briefly opens the launcher; keep the desktop free of interaction until it finishes.

The AppKit profile uses a separate UserDefaults suite, a named synthetic pasteboard, and an empty clipboard history. It reads the real application index and its cache, but does not install apps, register global shortcuts, open results, send AI prompts, or modify login settings. It exercises 180 queries and 400 selection moves with 117 applications on the measured machine. Query timing includes synchronous ranking, row creation and layout; navigation timing includes selection and scrolling. It yields between batches so pending UI updates contribute to total workload CPU time. File searches in this typing workload are generally cancelled before Spotlight's debounce expires.

`peak_rss_mib` is the test process's peak resident memory, including XCTest/AppKit overhead. `workload_cpu_seconds` includes user and system CPU for the process, measured separately from elapsed wall time. `idle_cpu_percent` samples five seconds after hiding the panel, with clipboard recording disabled. Startup measurements use an existing on-disk app cache and are not cold system startup numbers. None of these numbers include Spotlight's separate process or system compositor cost.

For live sessions, the app emits Points of Interest intervals under subsystem `com.kebloop.launcher`: `Query results`, `Render rows`, and `File search`. Record the release app with Instruments' Time Profiler, Allocations, and Points of Interest instruments to relate slow typing or file searches to CPU and allocation activity. File search intervals cover debounce through completion; cancellation also ends the interval. Signposts contain no query text, file paths, or clipboard content.

The standalone file visibility benchmark checks 512 canonical paths 200 times. It isolates exclusion classification; its memory numbers are not the launcher's memory usage. `KEBLOOP_PROFILE=1 swift test -c release --filter SearchTests/testThousandAppSearchPerformance` separately times ranking 1,000 synthetic entries. Timing profiles are opt-in and have no machine-dependent pass/fail latency threshold.

Optimizations in this change:

- Keyboard navigation updates two existing row highlights instead of recreating all rows and constraints.
- Hidden panels skip reactive ranking/rendering; unchanged file-search publications and irrelevant status renders are suppressed.
- Search normalizes names once per candidate and avoids temporary fuzzy-score arrays.
- Opening the launcher uses a five-minute app-index freshness window; explicit refresh still scans immediately.
- Icons have count/cost cache limits and only the first 32 applications are warmed. Other icons load on demand.
- File exclusions reuse constants and avoid repeated Foundation path conversions for canonical paths.
- Clipboard polling stops while disabled. The serial persistence writer retains only one active and one latest pending snapshot, avoiding a backlog of full-history saves. A controlled 500-update burst test produces two writes rather than 501; clear/remove remain the final saved state.

## Local results

Measured on arm64 macOS 27.0, Swift 6.4, release builds on 2026-10-12. Baseline source commit: `8bdf210da6aec3f36eaf8fd84c5a2a6833571b1f`. Baseline was built in an isolated temporary checkout with the same profile entry points. The raw samples are in [performance/local-results.json](performance/local-results.json).

Median of three runs per version (p95 rows are the median of each run’s p95):

| Metric | Baseline | Optimized |
| --- | ---: | ---: |
| Query median | 5.165 ms | 3.361 ms |
| Query p95 | 11.257 ms | 10.415 ms |
| Navigation median | 5.220 ms | 0.061 ms |
| Navigation p95 | 8.549 ms | 0.081 ms |
| Workload CPU | 5.529 s | 1.049 s |
| Workload elapsed | 5.988 s | 1.212 s |
| Peak process RSS | 161.203 MiB | 121.406 MiB |
| First panel show | 73.331 ms | 68.357 ms |
| Index ready | 413.676 ms | 374.689 ms |
| Hidden idle CPU | 0.114 % | 0.249 % |

The measured workload used 81% less CPU time and 25% less peak resident memory. Navigation improved by 86.1×. Query p95 changed only modestly. Idle CPU varied between runs and did not improve; no idle-CPU reduction is claimed. Startup is sensitive to disk cache and desktop load. These local measurements are not guarantees for other Macs or large clipboard/quicklink collections.

The standalone visibility benchmark’s repeated baseline runs took 2,111–2,158 ms versus 639–647 ms after optimization for 102,400 checks (about 3.3× faster). The final profiling script measured 625 ms. Its process RSS was approximately 69.2 MB before and 7.3 MB after; this is isolated allocation pressure, not a measurement of the app.
