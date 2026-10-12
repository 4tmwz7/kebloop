import AppKit
import Combine
import Foundation
import KebloopCore

enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openai
    case claude
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: "ChatGPT"
        case .claude: "Claude"
        case .local: "Siri"
        }
    }

    var settingsTitle: String {
        switch self {
        case .openai: "OpenAI (ChatGPT)"
        case .claude: "Claude"
        case .local: "Local (Siri)"
        }
    }

    var websiteURL: URL? {
        switch self {
        case .openai: URL(string: "https://chatgpt.com/")
        case .claude: URL(string: "https://claude.ai/new")
        case .local: nil
        }
    }

    func promptURL(_ prompt: String) -> URL? {
        switch self {
        case .openai: AIPromptURL.chatGPT(prompt)
        case .claude: AIPromptURL.claude(prompt)
        case .local: nil
        }
    }

    var explanation: String {
        switch self {
        case .openai: "Opens ChatGPT with your query already filled in."
        case .claude: "Opens Claude with your query in the link. You may need to sign in first."
        case .local: "Sends your query directly to Siri. Siri must be enabled, and Kebloop needs Accessibility access."
        }
    }
}

@MainActor
final class AIHandoffService: ObservableObject {
    static let providerStorageKey = "aiProvider"
    static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @Published var provider: AIProvider {
        didSet { defaults.set(provider.rawValue, forKey: Self.providerStorageKey) }
    }

    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let openURL: (URL) -> Bool
    private let siriApplicationURL: @MainActor () -> URL?
    private let submitSiriPrompt: @MainActor (String, URL, @escaping (String?) -> Void) -> Void

    init(
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        siriApplicationURL: (@MainActor () -> URL?)? = nil,
        submitSiriPrompt: (@MainActor (String, URL, @escaping (String?) -> Void) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.openURL = openURL
        self.siriApplicationURL = siriApplicationURL ?? { Self.defaultSiriApplicationURL() }
        let sender = SiriPromptSender()
        self.submitSiriPrompt = submitSiriPrompt ?? { prompt, url, completion in
            Self.defaultSubmitSiriPrompt(prompt, at: url, sender: sender, completion: completion)
        }

        let storedValue = defaults.string(forKey: Self.providerStorageKey)
        let storedProvider = storedValue.flatMap(AIProvider.init(rawValue:))
        provider = storedProvider ?? .openai
        if storedProvider == nil {
            defaults.set(AIProvider.openai.rawValue, forKey: Self.providerStorageKey)
        }
    }

    /// Opens a prompt-bearing cloud URL, or fills and submits Siri’s native query field.
    func handoff(_ text: String, completion: @escaping (String?) -> Void) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            completion("Enter a prompt first.")
            return
        }
        guard copyPrompt(prompt) else {
            completion("Kebloop couldn't copy the prompt to the clipboard.")
            return
        }

        if let websiteURL = provider.promptURL(prompt) {
            guard openURL(websiteURL) else {
                completion("Kebloop couldn't open \(provider.title) in your browser.")
                return
            }
            completion(nil)
            return
        }

        guard let siriURL = siriApplicationURL() else {
            completion("Siri isn't available on this Mac.")
            return
        }
        submitSiriPrompt(prompt, siriURL, completion)
    }

    private func copyPrompt(_ prompt: String) -> Bool {
        pasteboard.clearContents()
        let wrotePrompt = pasteboard.setString(prompt, forType: .string)
        let markedTransient = pasteboard.setPropertyList("1", forType: Self.transientPasteboardType)
        return wrotePrompt && markedTransient
    }

    private static func defaultSiriApplicationURL() -> URL? {
        let workspace = NSWorkspace.shared
        for bundleID in ["com.apple.campo", "com.apple.Siri"] {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) { return url }
        }
        let modern = URL(fileURLWithPath: "/System/Applications/Siri AI.app")
        if FileManager.default.fileExists(atPath: modern.path) { return modern }

        let fallback = URL(fileURLWithPath: "/System/Library/CoreServices/Siri.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private static func defaultSubmitSiriPrompt(_ prompt: String, at url: URL, sender: SiriPromptSender, completion: @escaping (String?) -> Void) {
        guard SiriPromptSender.isTrusted else {
            _ = SiriPromptSender.requestPermission()
            completion("Enable Kebloop in System Settings → Privacy & Security → Device Control and Data Access (Accessibility on older macOS). If already enabled, remove and re-add this build, then restart Kebloop.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                guard error == nil, let application else { completion("Kebloop couldn’t open Siri."); return }
                sender.submit(prompt, application: application, completion: completion)
            }
        }
    }
}
