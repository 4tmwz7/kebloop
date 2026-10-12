import Foundation

/// Stable identifiers shared by launcher menus and future command integrations.
enum ResultAction: String, CaseIterable {
    case open, reveal, copyPath, openWith, editQuicklink, pin, unpin, runWithInput, removeClipboardItem
    enum Kind { case application, file, quicklink, command, appleShortcut, clipboard, other }
    static func available(kind: Kind, pinned: Bool = false) -> [ResultAction] {
        if kind == .clipboard { return [.open, pinned ? .unpin : .pin, .removeClipboardItem] }
        var actions: [ResultAction] = [.open]
        switch kind {
        case .file: actions += [.reveal, .copyPath, .openWith]
        case .application: actions += [.reveal, .copyPath]
        case .quicklink: actions += [.editQuicklink]
        case .appleShortcut: actions += [.runWithInput]
        case .clipboard, .command, .other: break
        }
        if kind != .other && kind != .appleShortcut { actions.append(pinned ? .unpin : .pin) }
        return actions
    }
    var title: String {
        switch self {
        case .removeClipboardItem: return L("Remove Item")
        case .open: return L("Open")
        case .runWithInput: return L("Run with Input…")
        case .reveal: return L("Reveal in Finder")
        case .copyPath: return L("Copy Path")
        case .openWith: return L("Open With…")
        case .editQuicklink: return L("Edit Quicklink…")
        case .pin: return L("Pin to Favorites")
        case .unpin: return L("Unpin from Favorites")
        }
    }
}
