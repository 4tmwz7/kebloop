import Foundation
import XCTest
@testable import KebloopCore

final class AIPromptURLTests: XCTestCase {
    func testChatGPTUsesFixedOriginAndEncodesPromptAsQuery() throws {
        let prompt = "  Héllo 🌍 + 2\nWhat about a & b? #tag  "

        let url = try XCTUnwrap(AIPromptURL.chatGPT(prompt))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "chatgpt.com")
        XCTAssertEqual(components.path, "/")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: "Héllo 🌍 + 2\nWhat about a & b? #tag")])
        XCTAssertFalse(try XCTUnwrap(components.percentEncodedQuery).contains("+"))
    }

    func testClaudeUsesNewChatPathAndPreservesPromptExactlyAfterOuterTrim() throws {
        let prompt = "\n  summarize this\nsecond line\t "

        let url = try XCTUnwrap(AIPromptURL.claude(prompt))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.ai")
        XCTAssertEqual(components.path, "/new")
        XCTAssertEqual(components.queryItems?.first?.name, "q")
        XCTAssertEqual(components.queryItems?.first?.value, "summarize this\nsecond line")
    }

    func testEmptyOrWhitespacePromptHasNoURL() {
        XCTAssertNil(AIPromptURL.chatGPT(" \n\t "))
        XCTAssertNil(AIPromptURL.claude(""))
    }
}
