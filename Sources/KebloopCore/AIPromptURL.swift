import Foundation

/// Builds provider URLs that prefill a prompt in the provider's web interface.
public enum AIPromptURL {
    public static func chatGPT(_ prompt: String) -> URL? {
        makeURL(host: "chatgpt.com", path: "/", prompt: prompt)
    }

    public static func claude(_ prompt: String) -> URL? {
        makeURL(host: "claude.ai", path: "/new", prompt: prompt)
    }

    private static func makeURL(host: String, path: String, prompt: String) -> URL? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "q", value: trimmedPrompt)]

        // A plus is data here, so encode it instead of allowing form-style decoders
        // to read it as a space. URLComponents handles the remaining escaping.
        if let query = components.percentEncodedQuery {
            components.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url
    }
}
