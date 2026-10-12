import Foundation

/// Stable identifiers shared by launcher menus and future command integrations.
enum ResultAction: String, CaseIterable {
    case open, reveal, copyPath, openWith, editQuicklink, pin, unpin, runWithInput
    enum Kind { case application, file, quicklink, command, appleShortcut, other }
    static func available(kind: Kind, pinned: Bool = false) -> [ResultAction] {
        var actions: [ResultAction] = [.open]
        switch kind {
        case .file: actions += [.reveal, .copyPath, .openWith]
        case .application: actions += [.reveal, .copyPath]
        case .quicklink: actions += [.editQuicklink]
        case .appleShortcut: actions += [.runWithInput]
        case .command, .other: break
        }
        if kind != .other && kind != .appleShortcut { actions.append(pinned ? .unpin : .pin) }
        return actions
    }
    var title: String {
        switch self {
        case .open: return String(localized: "Open")
        case .runWithInput: return String(localized: "Run with Input…")
        case .reveal: return String(localized: "Reveal in Finder")
        case .copyPath: return String(localized: "Copy Path")
        case .openWith: return String(localized: "Open With…")
        case .editQuicklink: return String(localized: "Edit Quicklink…")
        case .pin: return String(localized: "Pin to Favorites")
        case .unpin: return String(localized: "Unpin from Favorites")
        }
    }
}
