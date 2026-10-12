import AppKit
import Combine
import KebloopCore
import os
import UniformTypeIdentifiers

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Menu-bar apps have no Edit menu to dispatch the usual field-editor shortcuts.
private final class SearchField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let editor = currentEditor() as? NSTextView else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "x": editor.cut(nil)
            case "v": editor.paste(nil)
            case "z": editor.undoManager?.undo()
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
            editor.undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private enum LauncherMode: String {
    case root, clipboard, quicklinks, webSearch
    var title: String {
        switch self {
        case .root: return "Results"
        case .clipboard: return "Clipboard History"
        case .quicklinks: return "Quicklinks"
        case .webSearch: return "Web Search"
        }
    }
    var placeholder: String {
        switch self {
        case .root: return "Search apps, links, or commands…"
        case .clipboard: return "Search clipboard history…"
        case .quicklinks: return "Search quicklinks…"
        case .webSearch: return "Search the web…"
        }
    }
}

private enum LauncherResult {
    case application(IndexedApplication)
    case calculation(CalculationResult)
    case command(LauncherCommand)
    case quicklink(Quicklink)
    case clipboard(ClipboardEntry)
    case file(FileSearchResult)
    case appleShortcut(AppleShortcut)
    case webSearch(String)
    var id: String {
        switch self {
        case .application(let app): return app.id
        case .calculation: return "calculator"
        case .command(let command): return "command:\(command.rawValue)"
        case .quicklink(let link): return "link:\(link.id)"
        case .clipboard(let entry): return "clipboard:\(entry.id)"
        case .file(let file): return "file:\(file.id)"
        case .appleShortcut(let shortcut): return "apple:\(shortcut.id)"
        case .webSearch: return "web-search"
        }
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class ResultButton: NSButton {
    var invoke: (() -> Void)?
    var contextInvoke: (() -> Void)?
    override func rightMouseDown(with event: NSEvent) { contextInvoke?() }
    var showsHint = true
    weak var selectionHint: NSTextField?

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.35 : 0.14).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = selected && NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionHint?.stringValue = selected && showsHint ? "↵" : ""
        setAccessibilityValue(selected ? "Selected" : "")
    }
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        setAccessibilityRole(.button)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func clicked() { invoke?() }
}

@MainActor
final class LauncherPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    var onSettings: (() -> Void)?
    var onEmoji: (() -> Void)?
    var onAI: ((String) -> Void)?
    var profileName: (() -> String)?
    var onCommand: ((LauncherCommand) -> Void)?
    var onEditQuicklink: ((Quicklink) -> Void)?
    private let personalization: PersonalizationStore
    private let appleShortcuts: AppleShortcutsService
    private let actionsMenu = ActionMenuController()
    private var actionMenuOpen: Bool { actionsMenu.isVisible }
    private let actionButton = NSButton(title: "Actions ⌘K", target: nil, action: nil)
    private var recentIDs = UserDefaults.standard.stringArray(forKey: "recentResults") ?? []
    private let launchApplication: (IndexedApplication, @escaping (Error?) -> Void) -> Void
    private var presentationRevision = 0
    private struct ExternalActionContext {
        let query: String
        let mode: LauncherMode
        let resultID: String
        let revision: Int
    }
    private let index: ApplicationIndex
    private let quicklinks: QuicklinkStore
    private let clipboard: ClipboardHistoryStore
    private let aliases: AppAliasStore
    private let ai: AIHandoffService
    private let aiButton = NSButton(title: "", target: nil, action: nil)
    private let clearHistoryButton = NSButton(title: "Clear…", target: nil, action: nil)
    private var isConfirmingClear = false
    private let files = FileSearchService()
    private var mode: LauncherMode = .root
    private static let performanceLog = OSLog(subsystem: "com.kebloop.launcher", category: .pointsOfInterest)
    private let search = AppSearch()
    private let calculator = CalculatorEngine()
    private let panel: LauncherPanel
    private let input = SearchField()
    private let rows = FlippedStackView()
    private let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private let backButton = NSButton()
    private let searchIcon = NSImageView()
    private let category = NSTextField(labelWithString: "APPLICATIONS")
    private var results: [LauncherResult] = []
    var currentQuery: String { input.stringValue }
    var resultIdentifiers: [String] { results.map(\.id) }
    private var selection = 0
    private var usage = UserDefaults.standard.dictionary(forKey: "usage") as? [String: Int] ?? [:]
    private var activeScreen: NSScreen?
    private var previousApp: NSRunningApplication?
    private var subscriptions = Set<AnyCancellable>()
    private var keyboardMonitor: Any?
    private var outsideMonitor: Any?
    private var message: String?

    init(index: ApplicationIndex, quicklinks: QuicklinkStore, clipboard: ClipboardHistoryStore, aliases: AppAliasStore, ai: AIHandoffService, personalization: PersonalizationStore? = nil, appleShortcuts: AppleShortcutsService? = nil, launchApplication: ((IndexedApplication, @escaping (Error?) -> Void) -> Void)? = nil) {
        self.index = index
        self.launchApplication = launchApplication ?? index.launch
        self.quicklinks = quicklinks
        self.clipboard = clipboard
        self.aliases = aliases
        self.ai = ai
        self.personalization = personalization ?? PersonalizationStore()
        self.appleShortcuts = appleShortcuts ?? AppleShortcutsService()
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.panel.isVisible, !self.actionsMenu.isVisible else { return }
                self.focusInput()
            }.store(in: &subscriptions)
        panel.setAccessibilityLabel("Kebloop launcher")
        buildInterface()
        self.personalization.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyPersonalization() }
        }.store(in: &subscriptions)
        self.appleShortcuts.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { guard let self, self.panel.isVisible else { return }; self.updateResults(preserveSelection: true) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification).sink { [weak self] _ in self?.applyPersonalization() }.store(in: &subscriptions)
        index.$applications.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in guard let self, self.panel.isVisible else { return }; self.updateResults(preserveSelection: true) }.store(in: &subscriptions)
        index.$iconRevision.dropFirst().throttle(for: .milliseconds(30), scheduler: DispatchQueue.main, latest: true).sink { [weak self] _ in
            guard let self, self.panel.isVisible else { return }; self.render()
        }.store(in: &subscriptions)
        quicklinks.$links.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in guard let self, self.panel.isVisible else { return }; self.updateResults(preserveSelection: true) }.store(in: &subscriptions)
        clipboard.$items.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.panel.isVisible, self.mode == .clipboard else { return }
            self.updateResults(preserveSelection: true)
        }.store(in: &subscriptions)
        files.$results.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.panel.isVisible, self.mode == .root else { return }
            self.updateResults(preserveSelection: true)
        }.store(in: &subscriptions)
        files.$isSearching.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.panel.isVisible, self.mode == .root, self.results.isEmpty else { return }; self.render()
        }.store(in: &subscriptions)
        aliases.$aliases.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.panel.isVisible else { return }; self.updateResults(preserveSelection: false)
        }.store(in: &subscriptions)
        ai.$provider.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in guard let self, self.panel.isVisible else { return }; self.render() }.store(in: &subscriptions)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow || self.actionsMenu.isKeyWindow else { return event }
            if self.actionsMenu.isVisible {
                if self.actionsMenu.handleKey(event) { return nil }
                return event
            }
            if (self.input.currentEditor() as? NSTextView)?.hasMarkedText() == true { return event }
            if LauncherKeyboard.isActionShortcut(event) { self.showActions(); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self.onSettings?(); return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
                self.dismiss(); return nil
            }
            if self.mode == .clipboard, event.modifierFlags.contains(.command), event.keyCode == 51 {
                if event.modifierFlags.contains(.shift) { self.confirmClearHistory() }
                else { self.removeSelectedClipboardItem() }
                return nil
            }
            if event.keyCode == 48, NSApp.isFullKeyboardAccessEnabled { return event }
            if event.keyCode == 48,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               self.mode == .root,
               (self.input.currentEditor() as? NSTextView)?.hasMarkedText() != true,
               !self.input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.askAI()
                return nil
            }
            switch event.keyCode {
            case 53:
                if self.mode == .root { self.dismiss() } else { self.enter(.root) }
                return nil
            case 125: self.moveSelection(1); return nil
            case 126: self.moveSelection(-1); return nil
            case 36, 76:
                if let button = self.panel.firstResponder as? ResultButton { button.invoke?() }
                else if let button = self.panel.firstResponder as? NSButton { button.performClick(nil) }
                else { self.performSelected() }
                return nil
            default: return event
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss(restoreFocus: false)
        }
    }

    deinit {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    }

    private func buildInterface() {
        scrollHeight?.isActive = false
        let content = NSView()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, personalization.settings.transparency, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            // Clip the window backing as well as the glass effect's rounded shape.
            glass.wantsLayer = true
            glass.layer?.cornerRadius = glass.cornerRadius
            glass.layer?.masksToBounds = true
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.contentView = content
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || !personalization.settings.transparency ? .inactive : .active
            material.wantsLayer = true
            material.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            material.wantsLayer = true
            material.layer?.cornerRadius = 20
            material.layer?.masksToBounds = true
            panel.contentView = material
            content.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                content.topAnchor.constraint(equalTo: material.topAnchor),
                content.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
        }

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let header = NSView()
        let icon = searchIcon
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.isHidden = true
        backButton.setAccessibilityLabel("Back to launcher")
        icon.contentTintColor = .secondaryLabelColor
        input.placeholderString = mode.placeholder
        input.font = .systemFont(ofSize: 19, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.setAccessibilityLabel("Search")
        input.cell?.isScrollable = true
        for view in [icon, backButton, input] { view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view) }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 56),
            backButton.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 20),
            backButton.heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            input.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            input.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            input.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        container.addArrangedSubview(header)
        addDivider(to: container)
        category.font = .systemFont(ofSize: 10, weight: .semibold)
        category.textColor = .tertiaryLabelColor
        let categoryWrapper = NSView()
        category.translatesAutoresizingMaskIntoConstraints = false
        categoryWrapper.addSubview(category)
        clearHistoryButton.target = self
        clearHistoryButton.action = #selector(confirmClearHistory)
        clearHistoryButton.isBordered = false
        clearHistoryButton.font = .systemFont(ofSize: 11)
        clearHistoryButton.translatesAutoresizingMaskIntoConstraints = false
        clearHistoryButton.setAccessibilityLabel("Clear clipboard history")
        categoryWrapper.addSubview(clearHistoryButton)
        aiButton.target = self
        aiButton.action = #selector(askAI)
        aiButton.isBordered = false
        aiButton.font = .systemFont(ofSize: 11)
        aiButton.translatesAutoresizingMaskIntoConstraints = false
        categoryWrapper.addSubview(aiButton)
        actionButton.target = self; actionButton.action = #selector(showActions)
        actionButton.isBordered = false; actionButton.font = .systemFont(ofSize: 11)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        categoryWrapper.addSubview(actionButton)
        NSLayoutConstraint.activate([
            categoryWrapper.heightAnchor.constraint(equalToConstant: 22),
            actionButton.trailingAnchor.constraint(equalTo: categoryWrapper.trailingAnchor, constant: -12),
            actionButton.centerYAnchor.constraint(equalTo: categoryWrapper.centerYAnchor),
            aiButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -12),
            aiButton.centerYAnchor.constraint(equalTo: categoryWrapper.centerYAnchor),
            category.trailingAnchor.constraint(lessThanOrEqualTo: aiButton.leadingAnchor, constant: -8),
            clearHistoryButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -12),
            clearHistoryButton.centerYAnchor.constraint(equalTo: categoryWrapper.centerYAnchor),
            category.leadingAnchor.constraint(equalTo: categoryWrapper.leadingAnchor, constant: 16),
            category.centerYAnchor.constraint(equalTo: categoryWrapper.centerYAnchor)
        ])
        container.addArrangedSubview(categoryWrapper)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 8, right: 6)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = rows
        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 330)
        scrollHeight.isActive = true
        container.addArrangedSubview(scrollView)
        for view in container.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
    }

    private func addDivider(to stack: NSStackView) {
        let line = NSBox()
        line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(line)
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow && NSApp.isActive { dismiss() }
        else { show() }
    }
    func show() {
        presentationRevision &+= 1
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
            if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
               let info = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == frontmost.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
               let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
               let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"], let primary = NSScreen.screens.first {
                let center = NSPoint(x: x + width / 2, y: primary.frame.maxY - y - height / 2)
                activeScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            }

        }
        panel.appearance = personalization.settings.appearance == "light" ? NSAppearance(named: .aqua) : (personalization.settings.appearance == "dark" ? NSAppearance(named: .darkAqua) : nil)
        files.configure(personalization.settings)
        index.searchEnabled = personalization.settings.appsEnabled
        index.refreshIfNeeded()
        mode = .root
        files.stop()
        input.stringValue = ""
        selection = 0
        message = nil
        updateResults()
        positionPanel()
        // Activation completes asynchronously. Focus now and again when AppKit
        // confirms activation, so a foreground editor cannot keep keyboard input.
        NSApp.activate(ignoringOtherApps: true)
        focusInput()
    }

    private func focusInput() {
        panel.makeKeyAndOrderFront(nil)
        // Re-entering an active field editor can replace text typed during activation.
        if let editor = input.currentEditor(), panel.firstResponder === editor { return }
        panel.makeFirstResponder(input)
    }

    func dismiss(restoreFocus: Bool = true) {
        guard panel.isVisible, !isConfirmingClear else { return }
        actionsMenu.close(restoreFocus: false)
        panel.orderOut(nil)
        files.stop()
        if restoreFocus, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
    }
    func windowDidResignKey(_ notification: Notification) { if !isConfirmingClear && !actionMenuOpen { dismiss(restoreFocus: false) } }
    func controlTextDidChange(_ obj: Notification) {
        setQuery(input.stringValue)
    }

    func setQuery(_ query: String) {
        if input.stringValue != query { input.stringValue = query }
        message = nil
        if mode == .root {
            if !personalization.settings.filesEnabled { files.stop() }
            else if case .result = calculator.evaluate(input.stringValue) { files.stop() }
            else { files.search(input.stringValue) }
        }
        updateResults()
    }
    func restorePreviousFocus() {
        previousApp?.activate(options: [])
    }
    @objc private func goBack() { enter(.root) }
    private func enter(_ next: LauncherMode) {
        mode = next
        input.stringValue = ""
        message = nil
        selection = 0
        files.stop()
        updateResults()
        panel.makeFirstResponder(input)
    }

    private func updateResults(preserveSelection: Bool = false) {
        let interval = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "Query results", signpostID: interval)
        defer { os_signpost(.end, log: Self.performanceLog, name: "Query results", signpostID: interval) }
        let selectedID = preserveSelection && results.indices.contains(selection) ? results[selection].id : nil
        let query = input.stringValue
        switch mode {
        case .root:
            let config = personalization.settings
            let appResults = config.appsEnabled ? index.applications.filter { !config.hiddenApps.contains($0.path) }.map(LauncherResult.application) : []
            let linkResults = config.linksEnabled ? quicklinks.links.map(LauncherResult.quicklink) : []
            let commands = config.commandsEnabled ? LauncherCommand.allCases.map(LauncherResult.command) : []
            let shortcutResults = config.commandsEnabled ? appleShortcuts.selected.map(LauncherResult.appleShortcut) : []
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let rankedApps = rank(appResults, query: "")
                let favorites = pinnedResults(from: appResults + linkResults + commands + shortcutResults)
                if config.emptyMode == "favorites" { results = favorites + commands.filter { !favorites.map(\.id).contains($0.id) } }
                else if config.emptyMode == "recent" { results = recentIDs.compactMap { id in (appResults + linkResults + shortcutResults).first { $0.id == id } } + commands }
                else { results = favorites + Array(rankedApps.filter { !favorites.map(\.id).contains($0.id) }.prefix(3)) + commands.filter { !favorites.map(\.id).contains($0.id) } }
            } else {
                results = Array(rank(appResults + linkResults + commands + shortcutResults, query: query).prefix(12))
                // Indexed files enrich results without delaying or overtaking app matches.
                results += files.results.filter { personalization.allowsFile(path: $0.path) }.prefix(12).map(LauncherResult.file)
                if config.linksEnabled, let resolved = quicklinks.resolve(query: query) { results.insert(.quicklink(resolved.link), at: 0); results = uniqueResults(results) }
                if config.linksEnabled, results.isEmpty, quicklinks.fallbackURL(query: query) != nil { results.append(.webSearch(query)) }
                switch calculator.evaluate(query) {
                case .result(let result): results.insert(.calculation(result), at: 0)
                case .failure(let error): message = error
                case .none, .incomplete: break
                }
            }
        case .webSearch:
            results = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quicklinks.fallbackURL(query: query) == nil ? [] : [.webSearch(query)]
        case .quicklinks:
            results = rank(quicklinks.links.map(LauncherResult.quicklink), query: query)
        case .clipboard:
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = clipboard.items.filter { trimmed.isEmpty || $0.text.localizedCaseInsensitiveContains(trimmed) }.map(LauncherResult.clipboard)
        }
        selection = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? (preserveSelection ? min(selection, max(0, results.count - 1)) : 0)
        render()
        if !preserveSelection {
            announceSelection()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func rank(_ candidates: [LauncherResult], query: String) -> [LauncherResult] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let entries = candidates.map { result -> AppSearchEntry in
            let name: String
            switch result {
            case .application(let app): name = app.name
            case .quicklink(let link): name = link.name
            case .command(let command): name = command.title
            case .appleShortcut(let shortcut): name = shortcut.name
            default: name = ""
            }
            let appAliases: [String]
            if case .application(let app) = result, let alias = aliases.alias(for: app) { appAliases = [alias] }
            else if case .command(let command) = result { appAliases = command.aliases }
            else { appAliases = [] }
            return AppSearchEntry(id: result.id, name: name, path: "", aliases: appAliases)
        }
        return search.ranked(query: query, entries: entries, usage: usage).compactMap { byID[$0.id] }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let previous = selection
        selection = min(max(0, selection + delta), results.count - 1)
        guard previous != selection else { return }
        (rows.arrangedSubviews[previous] as? ResultButton)?.setSelected(false)
        (rows.arrangedSubviews[selection] as? ResultButton)?.setSelected(true)
        rows.layoutSubtreeIfNeeded()
        if rows.arrangedSubviews.indices.contains(selection) {
            rows.scrollToVisible(rows.arrangedSubviews[selection].frame)
            announceSelection()
        }
    }

    private func render() {
        let interval = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "Render rows", signpostID: interval)
        defer { os_signpost(.end, log: Self.performanceLog, name: "Render rows", signpostID: interval) }
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        category.stringValue = mode.title + (profileName.map { " · " + $0() } ?? "")
        actionButton.isEnabled = !results.isEmpty
        actionButton.title = personalization.settings.showShortcutHints ? "Actions ⌘K" : "Actions"
        input.placeholderString = mode.placeholder
        searchIcon.isHidden = mode != .root
        backButton.isHidden = mode == .root
        clearHistoryButton.isHidden = mode != .clipboard
        clearHistoryButton.isEnabled = !clipboard.items.isEmpty
        aiButton.isHidden = mode != .root || input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        aiButton.title = "Ask \(ai.provider.title)" + (personalization.settings.showShortcutHints ? " ⇥" : "")
        aiButton.setAccessibilityLabel("Open \(ai.provider.title) with your query")
        aiButton.toolTip = "Send query to \(ai.provider.title) (Tab)"
        if results.isEmpty {
            let label = NSTextField(labelWithString: message ?? emptyMessage)
            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            rows.addArrangedSubview(label)
            label.heightAnchor.constraint(equalToConstant: 48).isActive = true
            label.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
        }
        for (position, result) in results.enumerated() {
            let button = ResultButton()
            button.wantsLayer = true
            button.layer?.cornerRadius = 10
            button.layer?.backgroundColor = position == selection ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
            let icon: NSImage?
            let title: String
            let subtitle: String
            let action: String
            switch result {
            case .application(let app):
                icon = index.icon(for: app) ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
                title = app.name
                let hasDuplicateName = index.applications.contains { $0.id != app.id && $0.name == app.name }
                subtitle = hasDuplicateName ? NSString(string: app.path).abbreviatingWithTildeInPath : "Application"
                action = "Open"
            case .command(let command):
                icon = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
                title = command.title
                switch command {
                case .settings: subtitle = "Preferences and shortcuts"
                case .shutdown: subtitle = "Shows macOS shutdown confirmation"
                default: subtitle = "Command"
                }
                action = "Open"
            case .appleShortcut(let shortcut):
                icon = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
                title = shortcut.name; subtitle = "Apple Shortcut"; action = "Run"
            case .webSearch(let query):
                icon = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                title = "Search the web for \(query)"; subtitle = "Opens your configured search website"; action = "Search"
            case .quicklink(let link):
                icon = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
                title = link.name
                let argument = quicklinks.resolve(query: input.stringValue).flatMap { $0.link.id == link.id ? $0.argument : nil } ?? ""
                subtitle = link.keyword.isEmpty ? link.target : "\(link.keyword) · \(link.resolvedURL(argument: argument)?.absoluteString ?? link.target)"
                action = "Open"
            case .clipboard(let entry):
                icon = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
                title = entry.preview
                subtitle = entry.date.formatted(date: .abbreviated, time: .shortened)
                action = "Copy"
            case .file(let file):
                icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                title = file.name
                subtitle = NSString(string: file.path).abbreviatingWithTildeInPath
                action = "Open"
            case .calculation(let result):
                icon = NSImage(systemSymbolName: "equal.square", accessibilityDescription: nil)
                title = result.display
                subtitle = result.expression
                action = "Copy answer"
            }
            let image = NSImageView()
            image.image = icon
            image.imageScaling = .scaleProportionallyUpOrDown
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: personalization.settings.textSize, weight: .medium)
            titleLabel.lineBreakMode = .byTruncatingTail
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: max(10, personalization.settings.textSize - 4))
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingMiddle
            let hint = NSTextField(labelWithString: position == selection && personalization.settings.showShortcutHints ? "↵" : "")
            hint.textColor = .secondaryLabelColor
            button.selectionHint = hint
            button.showsHint = personalization.settings.showShortcutHints
            for view in [image, titleLabel, subtitleLabel, hint] { view.translatesAutoresizingMaskIntoConstraints = false; button.addSubview(view) }
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: rowHeight),
                image.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
                image.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 28), image.heightAnchor.constraint(equalToConstant: 28),
                titleLabel.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
                titleLabel.topAnchor.constraint(equalTo: button.topAnchor, constant: 6),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -12),
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -12),
                hint.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: isClipboardResult(result) ? -40 : -10),
                hint.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            if case .clipboard(let entry) = result {
                let remove = ResultButton()
                remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove clipboard item")
                remove.contentTintColor = .secondaryLabelColor
                remove.translatesAutoresizingMaskIntoConstraints = false
                remove.setAccessibilityLabel("Remove clipboard item")
                remove.toolTip = "Remove item (⌘⌫)"
                remove.invoke = { [weak self] in self?.clipboard.remove(id: entry.id) }
                button.addSubview(remove)
                button.setAccessibilityChildren([remove])
                NSLayoutConstraint.activate([
                    remove.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
                    remove.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    remove.widthAnchor.constraint(equalToConstant: 24),
                    remove.heightAnchor.constraint(equalToConstant: 28)
                ])
            }
            button.setAccessibilityLabel("\(title), \(subtitle), \(action)")
            button.setSelected(position == selection)
            button.contextInvoke = { [weak self] in
                guard let self, let position = self.results.firstIndex(where: { $0.id == result.id }) else { return }
                self.selection = position; self.showActions()
            }
            button.invoke = { [weak self] in
                guard let self, let current = self.results.firstIndex(where: { $0.id == result.id }) else { return }
                self.selection = current; self.performSelected()
            }
            rows.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
        }
        if let message, !results.isEmpty {
            let errorLabel = NSTextField(wrappingLabelWithString: message)
            errorLabel.font = .systemFont(ofSize: 12)
            errorLabel.textColor = .secondaryLabelColor
            rows.addArrangedSubview(errorLabel)
            errorLabel.heightAnchor.constraint(equalToConstant: 40).isActive = true
            errorLabel.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
        }
        // Keep the top edge fixed while the result area expands or contracts.
        let resultHeight: Int = results.isEmpty ? 48 : Int(Double(results.count) * (rowHeight + 2)) - 2
        let errorHeight = message != nil && !results.isEmpty ? 42 : 0
        let documentHeight = CGFloat(resultHeight + errorHeight + 8)
        let visibleHeight = min(documentHeight, 330)
        rows.setFrameSize(NSSize(width: personalization.settings.panelWidth, height: documentHeight))
        scrollHeight.constant = visibleHeight
        let height = CGFloat(79) + visibleHeight
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - height, width: personalization.settings.panelWidth, height: height), display: true)
    }

    private var rowHeight: Double { max(personalization.settings.compact ? 40 : 48, personalization.settings.textSize * 2 + 16) }

    private func uniqueResults(_ candidates: [LauncherResult]) -> [LauncherResult] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private func pinnedResults(from candidates: [LauncherResult]) -> [LauncherResult] {
        personalization.pins.compactMap { pin in
            if let result = candidates.first(where: { $0.id == pin.id }) { return result }
            if pin.kind == "file", personalization.settings.filesEnabled, personalization.allowsFile(path: pin.path), FileManager.default.fileExists(atPath: pin.path) {
                return .file(FileSearchResult(name: pin.name, path: pin.path))
            }
            return nil
        }
    }

    private func recordRecent(_ id: String) {
        recentIDs.removeAll { $0 == id }; recentIDs.insert(id, at: 0)
        recentIDs = Array(recentIDs.prefix(20))
        UserDefaults.standard.set(recentIDs, forKey: "recentResults")
    }

    private func announceSelection() {
        guard rows.arrangedSubviews.indices.contains(selection) else { return }
        let row = rows.arrangedSubviews[selection]
        NSAccessibility.post(element: input, notification: .announcementRequested, userInfo: [
            .announcement: row.accessibilityLabel() ?? "", .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    func executeCommand(id: String) {
        guard personalization.settings.commandsEnabled else { return }
        if id.hasPrefix("apple:"), let shortcut = appleShortcuts.selected.first(where: { "apple:" + $0.id == id }) {
            show(); results = [.appleShortcut(shortcut)]; selection = 0; performSelected(); return
        }
        if id.hasPrefix("link:"), let link = quicklinks.links.first(where: { "link:" + $0.id == id }) {
            show(); results = [.quicklink(link)]; selection = 0; performSelected(); return
        }
        guard let command = LauncherCommand(rawValue: id.replacingOccurrences(of: "command:", with: "")) else { return }
        show(); results = [.command(command)]; selection = 0; performSelected()
    }

    private func applyPersonalization() {
        let config = personalization.settings
        panel.appearance = config.appearance == "light" ? NSAppearance(named: .aqua) : (config.appearance == "dark" ? NSAppearance(named: .darkAqua) : nil)
        buildInterface()
        index.searchEnabled = config.appsEnabled
        files.configure(config)
        if !config.filesEnabled { files.stop() }
        else if panel.isVisible { files.search(input.stringValue) }
        if panel.isVisible { updateResults(preserveSelection: true); positionPanel() }
    }

    private func positionPanel() {
        let config = personalization.settings
        let pointer = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let chosen = NSScreen.screens.first { String(describing: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "") == config.displayID }
        let screen = config.placement == "display" ? (chosen ?? pointer ?? NSScreen.main) : (config.placement == "active" ? (activeScreen ?? NSScreen.main ?? pointer) : (pointer ?? NSScreen.main))
        guard let screen else { return }
        let area = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(config.panelWidth, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = max(area.minX, min(area.maxX - frame.width, area.midX - frame.width / 2))
        frame.origin.y = max(area.minY, min(area.maxY - frame.height, area.maxY - max(80, area.height * 0.2) - frame.height))
        panel.setFrame(frame, display: true)
    }

    private func pin(for result: LauncherResult) -> PinnedResult? {
        switch result {
        case .application(let app): return PinnedResult(id: result.id, name: app.name, path: app.path, kind: "application")
        case .file(let file): return PinnedResult(id: result.id, name: file.name, path: file.path, kind: "file")
        case .quicklink(let link): return PinnedResult(id: result.id, name: link.name, path: link.target, kind: "quicklink")
        case .command(let command): return PinnedResult(id: result.id, name: command.title, path: "", kind: "command")
        default: return nil
        }
    }

    private func actionItems(for result: LauncherResult) -> [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        func add(_ action: ResultAction) {
            let title: String
            if action == .open {
                switch result {
                case .clipboard: title = String(localized: "Copy")
                case .calculation: title = String(localized: "Copy Answer")
                case .appleShortcut: title = String(localized: "Run")
                case .webSearch: title = String(localized: "Search")
                default: title = action.title
                }
            } else { title = action.title }
            items.append(ActionMenuItem(action: action, title: title))
        }
        let kind: ResultAction.Kind
        switch result {
        case .application: kind = .application
        case .file: kind = .file
        case .quicklink(let link): kind = quicklinks.links.contains { $0.id == link.id } ? .quicklink : .other
        case .command: kind = .command
        case .appleShortcut: kind = .appleShortcut
        default: kind = .other
        }
        for action in ResultAction.available(kind: kind, pinned: personalization.isPinned(id: result.id)) { add(action) }
        return items
    }

    @objc func showActions() {
        if actionsMenu.isVisible { actionsMenu.close(); return }
        guard results.indices.contains(selection) else { return }
        let result = results[selection]
        let title = rows.arrangedSubviews.indices.contains(selection) ? rows.arrangedSubviews[selection].accessibilityLabel() ?? mode.title : mode.title
        actionsMenu.show(items: actionItems(for: result), title: title, parent: panel,
                         opaque: !personalization.settings.transparency || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                         onChoose: { [weak self] action in self?.performResultAction(action, resultID: result.id) },
                         onClose: { [weak self] restoreFocus in
            guard let self, self.panel.isVisible else { return }
            if restoreFocus { self.focusInput(); self.announceSelection() }
            else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.panel.isVisible, !self.panel.isKeyWindow, !self.actionsMenu.isVisible else { return }
                    self.dismiss(restoreFocus: false)
                }
            }
        })
    }

    var isShowingActions: Bool { actionsMenu.isVisible }
    @discardableResult
    func handleActionKey(_ event: NSEvent) -> Bool { actionsMenu.handleKey(event) }

    private func performResultAction(_ action: ResultAction, resultID: String) {
        guard let position = results.firstIndex(where: { $0.id == resultID }) else {
            message = String(localized: "This result is no longer available."); render(); return
        }
        selection = position
        let result = results[position]
        let path: String?
        switch result { case .file(let file): path = file.path; case .application(let app): path = app.path; default: path = nil }
        switch action {
        case .open: performSelected()
        case .runWithInput:
            guard case .appleShortcut(let shortcut) = result else { return }
            let alert = NSAlert(); alert.messageText = String(localized: "Run Shortcut With Input")
            alert.informativeText = shortcut.name
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
            field.placeholderString = String(localized: "Text input"); field.setAccessibilityLabel(String(localized: "Shortcut text input"))
            alert.accessoryView = field; alert.addButton(withTitle: String(localized: "Run")); alert.addButton(withTitle: String(localized: "Cancel"))
            isConfirmingClear = true
            let response = alert.runModal(); isConfirmingClear = false
            if response == .alertFirstButtonReturn {
                let context = beginExternalAction()
                appleShortcuts.run(id: shortcut.id, input: field.stringValue) { [weak self] error in
                    if let error { self?.showExternalActionError(error, context: context) }
                }
            }

        case .pin, .unpin: if let pin = pin(for: result) { personalization.togglePin(pin); updateResults(preserveSelection: true) }
        case .editQuicklink: if case .quicklink(let link) = result { onEditQuicklink?(link) }
        case .copyPath:
            if let path { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        case .reveal:
            if let path, FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            else { message = String(localized: "This item no longer exists."); render() }
        case .openWith:
            guard let path else { return }
            guard FileManager.default.fileExists(atPath: path) else { message = "This file no longer exists."; render(); return }
            let picker = NSOpenPanel(); picker.title = String(localized: "Choose an application"); picker.directoryURL = URL(fileURLWithPath: "/Applications"); picker.allowedContentTypes = [.application]
            isConfirmingClear = true
            let response = picker.runModal(); isConfirmingClear = false
            if response == .OK, let application = picker.url {
                NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
                    Task { @MainActor in if let error { self?.message = error.localizedDescription; self?.render() } }
                }
            }
        }
    }

    @objc private func askAI() {
        guard mode == .root, !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onAI?(input.stringValue)
    }
    func showHandoffError(query: String, error: String) {
        show()
        input.stringValue = query
        updateResults()
        message = error
        render()
        panel.makeFirstResponder(input)
    }

    private func isClipboardResult(_ result: LauncherResult) -> Bool {
        if case .clipboard = result { return true }; return false
    }
    private func removeSelectedClipboardItem() {
        guard results.indices.contains(selection), case .clipboard(let entry) = results[selection] else { return }
        clipboard.remove(id: entry.id)
    }
    @objc private func confirmClearHistory() {
        guard !clipboard.items.isEmpty else { return }
        isConfirmingClear = true
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All saved clipboard items will be removed."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { clipboard.clear() }
        isConfirmingClear = false
        panel.makeKey()
        panel.makeFirstResponder(input)
        updateResults()
    }

    private var emptyMessage: String {
        switch mode {
        case .root: return files.isSearching ? "Searching files…" : (index.isRefreshing ? "Finding your apps…" : "No results")
        case .clipboard:
            if !clipboard.items.isEmpty { return "No matching clipboard items" }
            return clipboard.enabled ? "Copy some text to start your history" : "Clipboard history is paused in Settings"
        case .webSearch: return quicklinks.webSearches.isEmpty ? "Add a web search template in Settings" : "Type a query, then press Return to search"
        case .quicklinks: return quicklinks.links.isEmpty ? "Add quicklinks in Settings" : "No quicklinks found"
        }
    }

    private func beginExternalAction() -> ExternalActionContext {
        let context = ExternalActionContext(query: input.stringValue, mode: mode,
                                            resultID: results[selection].id, revision: presentationRevision)
        dismiss(restoreFocus: false)
        return context
    }

    private func showExternalActionError(_ error: String, context: ExternalActionContext) {
        // A delayed completion must not replace a launcher session the user reopened.
        guard !panel.isVisible, presentationRevision == context.revision else { return }
        show()
        mode = context.mode
        setQuery(context.query)
        selection = results.firstIndex { $0.id == context.resultID } ?? 0
        message = error
        render()
        positionPanel()
        focusInput()
    }

    var isVisible: Bool { panel.isVisible }
    func performSelected() {
        guard panel.isVisible, results.indices.contains(selection) else { return }
        recordRecent(results[selection].id)
        switch results[selection] {
        case .appleShortcut(let shortcut):
            let context = beginExternalAction()
            appleShortcuts.run(id: shortcut.id, input: nil) { [weak self] error in
                if let error { self?.showExternalActionError(error, context: context) }
            }
        case .webSearch(let query):
            guard let url = quicklinks.fallbackURL(query: query) else { return }
            let context = beginExternalAction()
            if !NSWorkspace.shared.open(url) { showExternalActionError("Couldn’t open web search.", context: context) }
        case .command(let command):
            switch command {
            case .clipboard: enter(.clipboard)
            case .quicklinks: enter(.quicklinks)
            case .emoji: onEmoji?()
            case .settings: onSettings?()
            case .webSearch: enter(.webSearch)
            case .browse, .help, .onboarding, .profiles, .appleShortcuts: onCommand?(command)
            case .shutdown:
                do {
                    try ShutdownService.requestConfirmation()
                    dismiss(restoreFocus: false)
                } catch {
                    message = "Couldn’t show shutdown confirmation: \(error.localizedDescription)"
                    render()
                }
            }
        case .quicklink(let link):
            let argument = quicklinks.resolve(query: input.stringValue).flatMap { $0.link.id == link.id ? $0.argument : nil } ?? ""
            guard let url = link.resolvedURL(argument: argument) else {
                message = "Couldn’t open this quicklink."; render(); return
            }
            let context = beginExternalAction()
            guard NSWorkspace.shared.open(url) else {
                showExternalActionError("Couldn’t open this quicklink.", context: context); return
            }
            usage[context.resultID, default: 0] += 1
            UserDefaults.standard.set(usage, forKey: "usage")
        case .clipboard(let entry):
            clipboard.copy(entry)
            dismiss()
        case .file(let file):
            let context = beginExternalAction()
            if !NSWorkspace.shared.open(file.url) { showExternalActionError("Couldn’t open this file.", context: context) }
        case .calculation(let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.clipboard, forType: .string)
            dismiss()
        case .application(let app):
            let context = beginExternalAction()
            launchApplication(app) { [weak self] error in
                guard let self else { return }
                if let error { self.showExternalActionError("Couldn’t open \(app.name): \(error.localizedDescription)", context: context) }
                else {
                    self.usage[app.id, default: 0] += 1
                    UserDefaults.standard.set(self.usage, forKey: "usage")
                }
            }
        }
    }
}
