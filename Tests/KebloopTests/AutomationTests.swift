import XCTest
@testable import Kebloop

final class AutomationTests: XCTestCase {
    func testArgumentsAreLiteralAndEnvironmentDoesNotInheritSecrets() throws {
        let output = try AutomationProcess().execute(executable: "/usr/bin/printf", arguments: ["%s", "$(touch /tmp/kebloop-injection); Łódź & cats"])
        XCTAssertEqual(output.stdout, "$(touch /tmp/kebloop-injection); Łódź & cats")
        let environment = try AutomationProcess().execute(executable: "/usr/bin/env", arguments: [])
        XCTAssertFalse(environment.stdout.contains("HOME="))
        XCTAssertFalse(environment.stdout.contains("TOKEN"))
    }
    func testMissingExecutableAndNonzeroExit() {
        XCTAssertThrowsError(try AutomationProcess().execute(executable: "/missing/kebloop", arguments: [])) { XCTAssertEqual($0 as? AutomationFailure, .missingExecutable) }
        XCTAssertThrowsError(try AutomationProcess().execute(executable: "/usr/bin/false", arguments: [])) { XCTAssertEqual($0 as? AutomationFailure, .failed(1)) }
    }
    func testOutputIsBoundedAndTimeoutTerminatesProcess() {
        XCTAssertThrowsError(try AutomationProcess().execute(executable: "/usr/bin/yes", arguments: [], outputLimit: 1024)) { XCTAssertEqual($0 as? AutomationFailure, .outputLimit) }
        let start = Date()
        XCTAssertThrowsError(try AutomationProcess().execute(executable: "/bin/sleep", arguments: ["30"], timeout: 0.05)) { XCTAssertEqual($0 as? AutomationFailure, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testCancellationBeforeLaunchAndDuringExecution() async {
        let cancelled = AutomationProcess(); cancelled.cancel()
        XCTAssertThrowsError(try cancelled.execute(executable: "/bin/sleep", arguments: ["30"])) { XCTAssertEqual($0 as? AutomationFailure, .cancelled) }
        let runner = AutomationProcess()
        let task = Task.detached { Result { try runner.execute(executable: "/bin/sleep", arguments: ["30"]) } }
        try? await Task.sleep(for: .milliseconds(50)); runner.cancel()
        switch await task.value { case .success: XCTFail("Expected cancellation"); case .failure(let error): XCTAssertEqual(error as? AutomationFailure, .cancelled) }
    }
    func testInputAndSeparateStreams() throws {
        let input = Data("first\nŁódź".utf8)
        let result = try AutomationProcess().execute(executable: "/bin/cat", arguments: [], input: input)
        XCTAssertEqual(result.stdout, "first\nŁódź"); XCTAssertEqual(result.stderr, "")
    }
    @MainActor
    func testImportedScriptsRequireReviewAndPersist() throws {
        let suite = "KebloopAutomation.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScriptCommandStore(defaults: defaults)
        let command = ScriptCommand(id: "test", title: "Test", description: "", executable: "/usr/bin/printf", arguments: ["hi"], enabled: true)
        try store.importCommands([command]); XCTAssertFalse(store.commands[0].enabled)
        var error: String?; store.run(id: command.id) { error = $0 }; XCTAssertNotNil(error)
        store.setEnabled(id: command.id, enabled: true)
        XCTAssertTrue(ScriptCommandStore(defaults: defaults).commands[0].enabled)
        store.remove(id: command.id); XCTAssertTrue(ScriptCommandStore(defaults: defaults).commands.isEmpty)
    }
    @MainActor
    func testExtensionLifecyclePreferencesAndCompatibility() throws {
        let suite = "KebloopExtensions.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExtensionStore(defaults: defaults)
        var manifest = ExtensionManifest(id: "example", name: "Example", description: "", apiVersion: 1, executable: "/usr/bin/true", arguments: [], preferences: [ExtensionPreference(id: "prefix", title: "Prefix", defaultValue: "Hello")], enabled: true)
        try store.install(manifest); XCTAssertFalse(store.manifests[0].enabled)
        store.setPreference(extensionID: manifest.id, key: "prefix", value: "Welcome")
        XCTAssertEqual(store.preferences(id: manifest.id)["prefix"], "Welcome")
        store.setPreference(extensionID: manifest.id, key: "secret", value: "should not save")
        XCTAssertNil(store.preferences(id: manifest.id)["secret"])
        store.setEnabled(id: manifest.id, enabled: true)
        XCTAssertTrue(ExtensionStore(defaults: defaults).manifests[0].enabled)
        manifest.apiVersion = 2; XCTAssertThrowsError(try store.install(manifest)); XCTAssertEqual(store.manifests.count, 1)
        store.remove(id: manifest.id); XCTAssertTrue(store.manifests.isEmpty); XCTAssertNil(defaults.object(forKey: "extensionPreferences.example"))
    }
    @MainActor
    func testExtensionRoundTripAndMalformedResponse() async throws {
        let suite = "KebloopExtensionExecution.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let response = "{\"apiVersion\":1,\"results\":[{\"id\":\"greeting\",\"title\":\"Hello\",\"detail\":\"Details\",\"actions\":[{\"id\":\"greet\",\"title\":\"Greet\"}]}],\"message\":\"Success\"}"
        let store = ExtensionStore(defaults: defaults)
        try store.install(ExtensionManifest(id: "test", name: "Test", description: "", apiVersion: 1, executable: "/usr/bin/printf", arguments: ["%s", response], preferences: []))
        store.setEnabled(id: "test", enabled: true); store.search(id: "test", query: "test")
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.error); XCTAssertEqual(store.results.first?.title, "Hello")
        store.perform(id: "test", resultID: "greeting", actionID: "greet")
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.error)
        store.perform(id: "test", resultID: "greeting", actionID: "unknown"); XCTAssertNotNil(store.error)
        try store.install(ExtensionManifest(id: "bad", name: "Bad", description: "", apiVersion: 1, executable: "/usr/bin/printf", arguments: ["bad JSON"], preferences: []))
        store.setEnabled(id: "bad", enabled: true); store.search(id: "bad", query: "")
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.error?.contains("malformed JSON") == true); XCTAssertTrue(store.results.isEmpty)
    }
    func testTimeoutAndCompletionStopOrdinaryDescendants() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("kebloop-child-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let child = "(/bin/sleep 0.4; /usr/bin/printf alive > '\(marker.path)') & "
        XCTAssertThrowsError(try AutomationProcess().execute(executable: "/bin/sh", arguments: ["-c", child + "wait"], timeout: 0.1))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        _ = try AutomationProcess().execute(executable: "/bin/sh", arguments: ["-c", child + "exit 0"])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testBothStreamsCountTowardLimit() throws {
        let value = try AutomationProcess().execute(executable: "/bin/sh", arguments: ["-c", "printf output; printf diagnostic >&2"])
        XCTAssertEqual(value.stdout, "output"); XCTAssertEqual(value.stderr, "diagnostic")
        XCTAssertThrowsError(try AutomationProcess().execute(executable: "/bin/sh", arguments: ["-c", "printf 123456; printf 123456 >&2"], outputLimit: 10)) { XCTAssertEqual($0 as? AutomationFailure, .outputLimit) }
    }
    @MainActor
    func testDisableCancelsSlowExtensionWithoutStaleResults() async throws {
        let suite = "KebloopExtensionCancellation.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExtensionStore(defaults: defaults)
        try store.install(ExtensionManifest(id: "slow", name: "Slow", description: "", apiVersion: 1, executable: "/bin/sleep", arguments: ["30"], preferences: []))
        store.setEnabled(id: "slow", enabled: true); store.search(id: "slow", query: "")
        XCTAssertTrue(store.isRunning)
        store.setEnabled(id: "slow", enabled: false)
        XCTAssertFalse(store.isRunning); XCTAssertTrue(store.results.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.error); XCTAssertTrue(store.results.isEmpty)
    }
    func testExtensionRejectsDuplicateResultsAndExcessiveActions() {
        let result = ExtensionResult(id: "one", title: "One", subtitle: nil, detail: nil, actions: [])
        XCTAssertThrowsError(try ExtensionResponse(apiVersion: 1, results: [result, result], message: nil).validate())
        XCTAssertThrowsError(try ExtensionResponse(apiVersion: 2, results: [], message: nil).validate())
    }
}


extension AutomationTests {
    @MainActor
    func testScriptSuccessAdditionalArgumentsAndExecutionErrors() async throws {
        let suite = "KebloopScriptExecution.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScriptCommandStore(defaults: defaults)
        try store.save(ScriptCommand(id: "literal", title: "Literal", description: "", executable: "/usr/bin/printf", arguments: ["%s"], enabled: true))
        let completed = expectation(description: "Literal completion")
        store.run(id: "literal", arguments: ["Łódź & $(nothing)"]) { XCTAssertNil($0); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(store.output?.stdout, "Łódź & $(nothing)"); XCTAssertNil(store.runningID)
        for (id, executable, arguments, timeout, expected) in [
            ("missing", "/missing/runtime", [], 1.0, "missing"),
            ("failure", "/usr/bin/false", [], 1.0, "status 1"),
            ("timeout", "/bin/sleep", ["30"], 0.05, "time limit"),
            ("output", "/usr/bin/yes", [], 1.0, "output limit")
        ] {
            try store.save(ScriptCommand(id: id, title: id, description: "", executable: executable, arguments: arguments, timeout: timeout, enabled: true))
            let failed = expectation(description: id)
            store.run(id: id) { XCTAssertTrue($0?.contains(expected) == true); failed.fulfill() }
            await fulfillment(of: [failed], timeout: 3)
            XCTAssertTrue(store.error?.contains(expected) == true); XCTAssertNil(store.output)
        }
    }
    @MainActor
    func testScriptDisableRemoveEditAndReloadCancelWithNoStaleOutput() async throws {
        let suite = "KebloopScriptLifecycle.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScriptCommandStore(defaults: defaults)
        for operation in ["disable", "remove", "edit", "reload"] {
            let slow = ScriptCommand(id: "slow", title: "Slow", description: "", executable: "/bin/sleep", arguments: ["30"], enabled: true)
            try store.save(slow)
            let cancelled = expectation(description: operation + " cancels")
            store.run(id: slow.id) { XCTAssertEqual($0, "Execution cancelled."); cancelled.fulfill() }
            XCTAssertEqual(store.runningID, slow.id)
            var busyError: String?; store.run(id: slow.id) { busyError = $0 }; XCTAssertEqual(busyError, "Another script is running.")
            switch operation {
            case "disable": store.setEnabled(id: slow.id, enabled: false)
            case "remove": store.remove(id: slow.id)
            case "edit": try store.save(ScriptCommand(id: slow.id, title: "Changed", description: "", executable: "/usr/bin/printf", arguments: ["fresh"], enabled: true))
            default: store.reload()
            }
            XCTAssertNil(store.runningID)
            try store.save(ScriptCommand(id: "fresh", title: "Fresh", description: "", executable: "/usr/bin/printf", arguments: ["fresh"], enabled: true))
            let fresh = expectation(description: "Fresh response")
            store.run(id: "fresh") { XCTAssertNil($0); fresh.fulfill() }
            await fulfillment(of: [cancelled, fresh], timeout: 3)
            XCTAssertEqual(store.output?.stdout, "fresh"); XCTAssertNil(store.error)
        }
    }
    @MainActor
    func testExtensionReplacementRemovalAndReloadClearStaleState() async throws {
        let suite = "KebloopExtensionLifecycle.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExtensionStore(defaults: defaults)
        let response = "{\"apiVersion\":1,\"results\":[{\"id\":\"one\",\"title\":\"Fresh\",\"actions\":[]}],\"message\":\"fresh\"}"
        let fresh = ExtensionManifest(id: "test", name: "Test", description: "", apiVersion: 1, executable: "/usr/bin/printf", arguments: ["%s", response], preferences: [])
        for operation in ["replace", "remove", "reload"] {
            try store.install(fresh); store.setEnabled(id: fresh.id, enabled: true); store.search(id: fresh.id, query: "")
            try await waitForExtension(store)
            XCTAssertEqual(store.results.first?.title, "Fresh")
            switch operation {
            case "replace": try store.install(fresh)
            case "remove": store.remove(id: fresh.id)
            default: store.reload()
            }
            XCTAssertTrue(store.results.isEmpty); XCTAssertNil(store.message); XCTAssertNil(store.activeID)
            try store.install(ExtensionManifest(id: "slow", name: "Slow", description: "", apiVersion: 1, executable: "/bin/sleep", arguments: ["30"], preferences: []))
            store.setEnabled(id: "slow", enabled: true); store.search(id: "slow", query: "")
            try store.install(fresh); store.setEnabled(id: fresh.id, enabled: true); store.search(id: fresh.id, query: "")
            try await waitForExtension(store)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.results.first?.title, "Fresh"); XCTAssertNil(store.error)
            store.remove(id: "slow")
        }
    }
    func testExtensionResponseSizeAndActionValidationAndInputBound() {
        let results = (0..<101).map { ExtensionResult(id: String($0), title: "Result", subtitle: nil, detail: nil, actions: []) }
        XCTAssertThrowsError(try ExtensionResponse(apiVersion: 1, results: results, message: nil).validate())
        let tooMany = (0..<21).map { ExtensionAction(id: String($0), title: "Action") }
        for actions in [tooMany, [ExtensionAction(id: "same", title: "A"), ExtensionAction(id: "same", title: "B")], [ExtensionAction(id: "", title: "A")]] {
            XCTAssertThrowsError(try ExtensionResponse(apiVersion: 1, results: [ExtensionResult(id: "one", title: "One", subtitle: nil, detail: nil, actions: actions)], message: nil).validate())
        }
        XCTAssertThrowsError(try AutomationProcess().execute(executable: "/bin/cat", arguments: [], input: Data(repeating: 65, count: 262_145)))
    }
    @MainActor
    func testProvidedScriptAndExtensionSamples() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = root.appendingPathComponent("examples/automation")
        let result = try AutomationProcess().execute(executable: "/bin/sh", arguments: [sample.appendingPathComponent("hello-script.sh").path, "Łódź & cats"])
        XCTAssertEqual(result.stdout, "Hello, Łódź & cats!\n")
        var manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: sample.appendingPathComponent("greeting-manifest.json")))
        manifest.arguments = [sample.appendingPathComponent("greeting-extension.swift").path]
        let suite = "KebloopSamples.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExtensionStore(defaults: defaults)
        try store.install(manifest); store.setEnabled(id: manifest.id, enabled: true)
        store.setPreference(extensionID: manifest.id, key: "prefix", value: "Cześć")
        store.search(id: manifest.id, query: "Łódź & cats")
        try await waitForExtension(store)
        XCTAssertNil(store.error); XCTAssertEqual(store.results.first?.title, "Cześć, Łódź & cats!")
        XCTAssertEqual(store.results.first?.detail, "This native detail view comes from a JSON response.")
        store.perform(id: manifest.id, resultID: "greeting", actionID: "greet")
        try await waitForExtension(store)
        XCTAssertNil(store.error); XCTAssertEqual(store.message, "Greeting action completed.")
    }
    @MainActor
    func testExtensionRemoveEditReloadDuringRunCancelAndDiscardResponses() async throws {
        let suite = "KebloopExtensionActiveLifecycle.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExtensionStore(defaults: defaults)
        for operation in ["remove", "edit", "reload"] {
            let slow = ExtensionManifest(id: "slow", name: "Slow", description: "", apiVersion: 1, executable: "/bin/sleep", arguments: ["30"], preferences: [])
            try store.install(slow); store.setEnabled(id: slow.id, enabled: true); store.search(id: slow.id, query: "")
            XCTAssertTrue(store.isRunning)
            switch operation {
            case "remove": store.remove(id: slow.id)
            case "edit": try store.install(ExtensionManifest(id: slow.id, name: "Updated", description: "", apiVersion: 1, executable: "/usr/bin/printf", arguments: ["{\"apiVersion\":1,\"results\":[]}"], preferences: []))
            default: store.reload()
            }
            XCTAssertFalse(store.isRunning); XCTAssertTrue(store.results.isEmpty); XCTAssertNil(store.activeID)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(store.error); XCTAssertTrue(store.results.isEmpty)
            if operation == "edit" { XCTAssertFalse(try XCTUnwrap(store.manifests.first).enabled) }
        }
    }
    @MainActor
    func testExtensionErrorsAndTimeoutLeaveMainActorResponsive() async throws {
        let suite = "KebloopExtensionErrors.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExtensionStore(defaults: defaults)
        for (id, executable, arguments, expected) in [
            ("missing", "/missing/runtime", [], "missing"),
            ("crash", "/usr/bin/false", [], "status 1"),
            ("output", "/usr/bin/yes", [], "output limit"),
            ("version", "/usr/bin/printf", ["%s", "{\"apiVersion\":2,\"results\":[]}"], "incompatible"),
            ("slow", "/bin/sleep", ["30"], "time limit")
        ] {
            try store.install(ExtensionManifest(id: id, name: id, description: "", apiVersion: 1, executable: executable, arguments: arguments, preferences: []))
            store.setEnabled(id: id, enabled: true)
            let start = ProcessInfo.processInfo.systemUptime
            store.search(id: id, query: "test")
            if id == "slow" {
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertTrue(store.isRunning)
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1, "Main actor must remain responsive")
            }
            try await waitForExtension(store)
            XCTAssertTrue(store.error?.contains(expected) == true, "Expected \(expected), got \(store.error ?? "no error")")
            XCTAssertTrue(store.results.isEmpty)
        }
    }
    @MainActor
    func testScriptValidationAndImportAreAtomic() throws {
        let suite = "KebloopScriptValidation.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScriptCommandStore(defaults: defaults)
        let valid = ScriptCommand(id: "valid", title: "Valid", description: "", executable: "/usr/bin/true", arguments: [])
        for timeout in [0, 301, Double.nan, Double.infinity] {
            var invalid = valid; invalid.timeout = timeout
            XCTAssertThrowsError(try store.save(invalid)); XCTAssertTrue(store.commands.isEmpty)
        }
        var invalid = valid; invalid.executable = "relative/path"
        XCTAssertThrowsError(try store.importCommands([valid, invalid])); XCTAssertTrue(store.commands.isEmpty)
        invalid = valid; invalid.arguments = ["nul\0argument"]
        XCTAssertThrowsError(try store.save(invalid)); XCTAssertNil(defaults.data(forKey: "scriptCommands"))
    }
    @MainActor
    private func waitForExtension(_ store: ExtensionStore) async throws {
        for _ in 0..<700 where store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isRunning, "Extension did not finish within its runtime limit")
    }
}
