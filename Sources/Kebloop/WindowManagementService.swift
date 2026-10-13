import AppKit
import ApplicationServices

@MainActor
final class WindowManagementService {
    enum Action: CaseIterable { case leftHalf, rightHalf, maximize, center, restore, nextDisplay }
    enum Failure: LocalizedError {
        case permission, noWindow, unsupported, noRestore, noOtherDisplay, accessibility(AXError)
        var errorDescription: String? {
            switch self {
            case .permission: return "Enable Kebloop in System Settings → Privacy & Security → Accessibility to arrange windows."
            case .noWindow: return "The previous application has no focused window."
            case .unsupported: return "This window cannot be arranged. Full-screen, minimized, sheet, and fixed-size windows are excluded."
            case .noRestore: return "There is no saved frame for this window."
            case .noOtherDisplay: return "Connect another display to move this window."
            case .accessibility(let code): return "The application could not arrange its window (Accessibility error \(code.rawValue))."
            }
        }
    }
    private struct SavedFrame { let window: AXUIElement; let frame: CGRect }
    private var savedFrames: [SavedFrame] = []
    private let maximumSavedFrames = 64

    func perform(_ action: Action, application: NSRunningApplication?) throws {
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw Failure.permission
        }
        guard let application, !application.isTerminated, application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw Failure.noWindow }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw Failure.noWindow }
        let window = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)
        guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              ((attribute(window, "AXSheets") as? [AXUIElement]) ?? []).isEmpty,
              !boolean(window, kAXMinimizedAttribute), !boolean(window, "AXFullScreen"),
              settable(window, kAXPositionAttribute), settable(window, kAXSizeAttribute) else { throw Failure.unsupported }
        let original = try frame(window)
        // Accessibility uses the primary display's top-left as its origin; AppKit uses bottom-left.
        guard let primary = NSScreen.screens.first else { throw Failure.noWindow }
        let bounds = NSScreen.screens.map { Self.accessibilityRect($0.visibleFrame, primaryHeight: primary.frame.maxY) }
        let currentIndex = Self.screenIndex(for: original, screens: bounds)
        guard let currentIndex else { throw Failure.noWindow }
        let savedIndex = savedFrames.firstIndex { CFEqual($0.window, window) }
        let destination: CGRect
        if action == .restore {
            guard let savedIndex else { throw Failure.noRestore }
            let saved = savedFrames[savedIndex].frame
            let targetIndex = Self.screenIndex(for: saved, screens: bounds) ?? currentIndex
            destination = Self.clamp(saved, to: bounds[targetIndex])
        } else if action == .nextDisplay {
            guard bounds.count > 1 else { throw Failure.noOtherDisplay }
            destination = Self.move(original, from: bounds[currentIndex], to: bounds[(currentIndex + 1) % bounds.count])
        } else { destination = Self.arrangedFrame(action, original: original, screen: bounds[currentIndex]) }
        if savedIndex == nil && action != .restore {
            if savedFrames.count >= maximumSavedFrames { savedFrames.removeFirst() }
            savedFrames.append(SavedFrame(window: window, frame: original))
        }
        do { try setFrame(destination, window: window) }
        catch { try? setFrame(original, window: window); throw error }
        if action == .restore, let savedIndex { savedFrames.remove(at: savedIndex) }
    }

    static func accessibilityRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    static func screenIndex(for frame: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        return screens.indices.max { lhs, rhs in
            let a = frame.intersection(screens[lhs]), b = frame.intersection(screens[rhs])
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
    }
    static func arrangedFrame(_ action: Action, original: CGRect, screen: CGRect) -> CGRect {
        switch action {
        case .leftHalf: return CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .rightHalf: return CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .maximize: return screen
        case .center:
            let size = CGSize(width: min(original.width, screen.width), height: min(original.height, screen.height))
            return CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        case .restore, .nextDisplay: return clamp(original, to: screen)
        }
    }
    static func clamp(_ frame: CGRect, to screen: CGRect) -> CGRect {
        let width = min(frame.width, screen.width), height = min(frame.height, screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }
    static func move(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        clamp(CGRect(x: destination.minX + (frame.minX - source.minX) / source.width * destination.width,
                     y: destination.minY + (frame.minY - source.minY) / source.height * destination.height,
                     width: frame.width, height: frame.height), to: destination)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func boolean(_ element: AXUIElement, _ name: String) -> Bool { attribute(element, name) as? Bool == true }
    private func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }
    private func frame(_ window: AXUIElement) throws -> CGRect {
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw Failure.noWindow }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { throw Failure.noWindow }
        return CGRect(origin: point, size: size)
    }
    private func setFrame(_ frame: CGRect, window: AXUIElement) throws {
        var size = frame.size, point = frame.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &point) else { throw Failure.unsupported }
        for (name, value) in [(kAXSizeAttribute, s), (kAXPositionAttribute, p)] {
            let result = AXUIElementSetAttributeValue(window, name as CFString, value)
            guard result == .success else { throw Failure.accessibility(result) }
        }
    }
}
