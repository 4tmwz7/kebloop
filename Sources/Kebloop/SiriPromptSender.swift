import AppKit
import ApplicationServices

/// Only identifies Siri's composer, never arbitrary editable fields in its windows.
struct SiriElementDescriptor: Equatable {
    let role: String
    let identifier: String
    let placeholder: String
    let enabled: Bool

    var isPrompt: Bool {
        enabled && [kAXTextFieldRole, kAXTextAreaRole].contains(role)
            && (identifier == "promptViewTextField" || placeholder == "Ask Siri")
    }

    var isNewConversation: Bool {
        enabled && role == kAXButtonRole && identifier == "newChatButton"
    }
}

@MainActor
final class SiriPromptSender {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() -> Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
    }

    private let permissionGranted: () -> Bool
    private var operation: Task<Void, Never>?

    init(permissionGranted: (() -> Bool)? = nil) {
        self.permissionGranted = permissionGranted ?? { Self.isTrusted }
    }

    func submit(_ prompt: String, application: NSRunningApplication, completion: @escaping (String?) -> Void) {
        operation?.cancel()
        guard permissionGranted() else {
            completion("Allow Kebloop in System Settings → Privacy & Security → Accessibility to send text directly to Siri.")
            return
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion("Enter a prompt first.")
            return
        }
        guard ["com.apple.campo", "com.apple.Siri"].contains(application.bundleIdentifier ?? "") else {
            completion("Kebloop couldn't find the Siri application.")
            return
        }

        NSApp.yieldActivation(to: application)
        application.activate(options: [.activateAllWindows])
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.2)
            if let window = (self.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            var startedNewConversation = false
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                guard self.permissionGranted() else {
                    completion("Allow Kebloop in System Settings → Privacy & Security → Accessibility to send text directly to Siri.")
                    return
                }
                let elements = self.windowElements(appElement)
                let composer = elements.first(where: { self.descriptor($0).isPrompt })
                // New Conversation can discard a draft, so inspect the composer first.
                if !startedNewConversation, let composer {
                    guard let draft = self.attribute(composer, kAXValueAttribute) as? String else {
                        completion("Siri's text input isn't ready. Try again once Type to Siri is visible.")
                        return
                    }
                    guard draft.isEmpty else {
                        completion("Siri has an unsent draft. Send or clear it, then try again.")
                        return
                    }
                }
                // With no conversation selected, New Conversation creates the composer.
                if !startedNewConversation,
                   let newChat = elements.first(where: { self.descriptor($0).isNewConversation }),
                   AXUIElementPerformAction(newChat, kAXPressAction as CFString) == .success {
                    startedNewConversation = true
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    continue
                }
                if let input = composer {
                    // The window can be available before application activation completes.
                    guard application.isActive else {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        continue
                    }
                    guard let draft = self.attribute(input, kAXValueAttribute) as? String else {
                        completion("Siri's text input isn't ready. Try again once Type to Siri is visible.")
                        return
                    }
                    guard draft.isEmpty else {
                        completion("Siri has an unsent draft. Send or clear it, then try again.")
                        return
                    }
                    guard AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                          AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, prompt as CFString) == .success,
                          self.stringAttribute(input, kAXValueAttribute) == prompt else {
                        completion("Siri couldn't accept the prompt. Enable Type to Siri in System Settings and try again.")
                        return
                    }
                    // Let Siri commit the AX value into its input model before confirmation.
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    // Check Siri and its composer immediately before submitting.
                    guard !Task.isCancelled, application.isActive,
                          self.isFocused(input), self.stringAttribute(input, kAXValueAttribute) == prompt else {
                        completion("The prompt is in Siri, but Siri lost focus before it could be sent.")
                        return
                    }
                    guard AXUIElementPerformAction(input, kAXConfirmAction as CFString) == .success else {
                        completion("The query is in Siri, but this Siri version couldn't submit it directly. Press Return in Siri.")
                        return
                    }
                    for _ in 0..<20 {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard !Task.isCancelled else { return }
                        if let value = self.attribute(input, kAXValueAttribute) as? String, value != prompt {
                            completion(nil)
                            return
                        }
                        // Siri may replace its composer when beginning a response.
                        if let replacement = self.windowElements(appElement).first(where: { self.descriptor($0).isPrompt }),
                           !CFEqual(replacement, input),
                           let value = self.attribute(replacement, kAXValueAttribute) as? String, value != prompt {
                            completion(nil)
                            return
                        }
                    }
                    completion("The query is in Siri, but submission couldn't be confirmed. Check Siri before sending again.")
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            completion("Kebloop couldn't find Siri's text input. Enable Siri and Type to Siri in System Settings, then try again.")
        }
    }

    private func descriptor(_ element: AXUIElement) -> SiriElementDescriptor {
        SiriElementDescriptor(
            role: stringAttribute(element, kAXRoleAttribute),
            identifier: stringAttribute(element, kAXIdentifierAttribute),
            placeholder: stringAttribute(element, kAXPlaceholderValueAttribute),
            enabled: attribute(element, kAXEnabledAttribute) as? Bool ?? false
        )
    }

    private func windowElements(_ application: AXUIElement) -> [AXUIElement] {
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var stack = windows.map { ($0, 0) }
        var elements: [AXUIElement] = []
        while let (element, depth) = stack.popLast(), elements.count < 800 {
            elements.append(element)
            guard depth < 12 else { continue }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            stack.append(contentsOf: children.prefix(800 - elements.count).map { ($0, depth + 1) })
        }
        return elements
    }

    private func isFocused(_ input: AXUIElement) -> Bool {
        guard let focused = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(focused, input)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
