import AppKit

@MainActor
enum ApplicationControlService {
    enum Action { case quit, forceQuit, restart, toggleFocus, hide }
    enum Failure: LocalizedError {
        case notRunning, rejected, restartTimeout
        var errorDescription: String? {
            switch self {
            case .notRunning: return "This application is not running."
            case .rejected: return "The application declined the request. Save your work and try again."
            case .restartTimeout: return "The application did not quit. Restart was cancelled to protect unsaved work."
            }
        }
    }
    static func runningApplication(at url: URL) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && !$0.isTerminated }
    }
    static func isRunning(_ app: IndexedApplication) -> Bool { runningApplication(at: app.url) != nil }

    static func perform(_ action: Action, for app: IndexedApplication, completion: @escaping (Error?) -> Void) {
        guard let running = runningApplication(at: app.url) else {
            if action == .toggleFocus { launch(app.url, completion: completion) }
            else { completion(Failure.notRunning) }
            return
        }
        switch action {
        case .hide: completion(running.hide() ? nil : Failure.rejected)
        case .quit: completion(running.terminate() ? nil : Failure.rejected)
        case .forceQuit: completion(running.forceTerminate() ? nil : Failure.rejected)
        case .toggleFocus:
            let succeeded = running.isActive ? running.hide() : running.activate(options: [.activateAllWindows])
            completion(succeeded ? nil : Failure.rejected)
        case .restart:
            guard running.terminate() else { completion(Failure.rejected); return }
            Task { @MainActor in
                // Never launch a replacement while an unsaved-document prompt is pending.
                for _ in 0..<100 {
                    if running.isTerminated { launch(app.url, completion: completion); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                completion(Failure.restartTimeout)
            }
        }
    }
    private static func launch(_ url: URL, completion: @escaping (Error?) -> Void) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
