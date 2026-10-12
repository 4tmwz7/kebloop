import AppKit
import XCTest
@testable import Kebloop

@MainActor
final class AIHandoffTests: XCTestCase {
    func testProvidersExposeWebsiteTargetsAndHandoffGuidance() throws {
        XCTAssertEqual(AIProvider.allCases, [.openai, .claude, .local])
        XCTAssertEqual(try XCTUnwrap(AIProvider.openai.websiteURL).absoluteString, "https://chatgpt.com/")
        XCTAssertEqual(try XCTUnwrap(AIProvider.claude.websiteURL).absoluteString, "https://claude.ai/new")
        XCTAssertNil(AIProvider.local.websiteURL)
        XCTAssertEqual(AIProvider.openai.settingsTitle, "OpenAI (ChatGPT)")
        XCTAssertEqual(AIProvider.local.settingsTitle, "Local (Siri)")
        XCTAssertTrue(AIProvider.openai.explanation.contains("filled in"))
        XCTAssertTrue(AIProvider.claude.explanation.contains("query in the link"))
        XCTAssertTrue(AIProvider.local.explanation.contains("Accessibility"))
    }

    func testProviderPreferencePersistsAndInvalidValueFallsBackToOpenAI() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown-provider", forKey: AIHandoffService.providerStorageKey)

        let service = AIHandoffService(defaults: defaults, openURL: { _ in true })
        XCTAssertEqual(service.provider, .openai)
        XCTAssertEqual(defaults.string(forKey: AIHandoffService.providerStorageKey), AIProvider.openai.rawValue)

        service.provider = .claude
        XCTAssertEqual(AIHandoffService(defaults: defaults).provider, .claude)
    }

    func testCloudHandoffCopiesTrimmedPromptMarksItTransientAndOpensSite() throws {
        let (defaults, suite) = try makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
        }
        var openedURLs: [URL] = []
        let service = AIHandoffService(
            defaults: defaults,
            pasteboard: pasteboard,
            openURL: { openedURLs.append($0); return true }
        )
        service.provider = .claude
        var result: String? = "not completed"

        service.handoff("\n  Héllo 🌍\nsecond line  \t\n") { result = $0 }

        XCTAssertNil(result)
        XCTAssertEqual(openedURLs, [AIProvider.claude.promptURL("Héllo 🌍\nsecond line")])
        XCTAssertEqual(pasteboard.string(forType: .string), "Héllo 🌍\nsecond line")
        XCTAssertTrue(pasteboard.types?.contains(AIHandoffService.transientPasteboardType) == true)
    }

    func testEmptyPromptIsRejectedWithoutOpeningProvider() throws {
        let (defaults, suite) = try makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
        }
        var openCalled = false
        let service = AIHandoffService(defaults: defaults, pasteboard: pasteboard, openURL: { _ in
            openCalled = true
            return true
        })
        var result: String?
        service.handoff(" \n\t ") { result = $0 }

        XCTAssertEqual(result, "Enter a prompt first.")
        XCTAssertFalse(openCalled)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testLocalProviderSendsPromptToResolvedSiriApp() throws {
        let (defaults, suite) = try makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
        }
        let fakeSiriURL = URL(fileURLWithPath: "/Applications/Fake Siri.app")
        var openedURL: URL?
        var submittedPrompt: String?
        let service = AIHandoffService(
            defaults: defaults,
            pasteboard: pasteboard,
            siriApplicationURL: { fakeSiriURL },
            submitSiriPrompt: { prompt, url, completion in
                submittedPrompt = prompt
                openedURL = url
                completion(nil)
            }
        )
        service.provider = .local
        let completed = expectation(description: "Siri handoff completes")

        service.handoff("summarize this") { error in
            XCTAssertNil(error)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(openedURL, fakeSiriURL)
        XCTAssertEqual(submittedPrompt, "summarize this")
        XCTAssertEqual(pasteboard.string(forType: .string), "summarize this")
    }

    func testSiriSubmissionErrorIsReturnedToLauncher() throws {
        let (defaults, suite) = try makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
        }
        let service = AIHandoffService(
            defaults: defaults,
            pasteboard: pasteboard,
            siriApplicationURL: { URL(fileURLWithPath: "/System/Applications/Siri AI.app") },
            submitSiriPrompt: { _, _, completion in completion("Accessibility required") }
        )
        service.provider = .local
        var result: String?
        service.handoff("What is 2 plus 2?") { result = $0 }
        XCTAssertEqual(result, "Accessibility required")
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "KebloopAIHandoffTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}
