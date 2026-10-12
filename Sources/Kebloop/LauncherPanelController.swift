import AppKit
import Combine
import KebloopCore

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
    case root, clipboard, quicklinks
    var title: String {
        switch self {
        case .root: return "Results"
        case .clipboard: return "Clipboard History"
        case .quicklinks: return "Quicklinks"
        }
    }
    var placeholder: String {
        switch self {
        case .root: return "Search apps, links, or commands…"
        case .clipboard: return "Search clipboard history…"
        case .quicklinks: return "Search quicklinks…"
        }
    }
}

private enum LauncherCommand: String, CaseIterable {
    case clipboard, quicklinks, emoji, settings
    var title: String {
        switch self {
        case .clipboard: return "Clipboard History"
        case .quicklinks: return "Quicklinks"
        case .emoji: return "Emoji & Symbols"
        case .settings: return "Open Settings"
        }
    }
    var symbol: String {
        switch self {
        case .clipboard: return "clipboard"
        case .quicklinks: return "link"
        case .emoji: return "face.smiling"
        case .settings: return "gearshape"
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
    var id: String {
        switch self {
        case .application(let app): return app.id
        case .calculation: return "calculator"
        case .command(let command): return "command:\(command.rawValue)"
        case .quicklink(let link): return "link:\(link.id)"
        case .clipboard(let entry): return "clipboard:\(entry.id)"
        case .file(let file): return "file:\(file.id)"
        }
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class ResultButton: NSButton {
    var invoke: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func clicked() { invoke?() }
}

@MainActor
final class LauncherPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    var onSettings: (() -> Void)?
    var onEmoji: (() -> Void)?
    var onAI: ((String) -> Void)?
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
    private var selection = 0
    private var usage = UserDefaults.standard.dictionary(forKey: "usage") as? [String: Int] ?? [:]
    private var previousApp: NSRunningApplication?
    private var subscriptions = Set<AnyCancellable>()
    private var keyboardMonitor: Any?
    private var outsideMonitor: Any?
    private var message: String?

    init(index: ApplicationIndex, quicklinks: QuicklinkStore, clipboard: ClipboardHistoryStore, aliases: AppAliasStore, ai: AIHandoffService) {
        self.index = index
        self.quicklinks = quicklinks
        self.clipboard = clipboard
        self.aliases = aliases
        self.ai = ai
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
                guard let self, self.panel.isVisible else { return }
                self.focusInput()
            }.store(in: &subscriptions)
        panel.setAccessibilityLabel("Kebloop launcher")
        buildInterface()
        index.$applications.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateResults(preserveSelection: true) }.store(in: &subscriptions)
        index.$iconRevision.dropFirst().throttle(for: .milliseconds(30), scheduler: DispatchQueue.main, latest: true).sink { [weak self] _ in
            guard let self, self.panel.isVisible else { return }; self.render()
        }.store(in: &subscriptions)
        quicklinks.$links.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateResults(preserveSelection: true) }.store(in: &subscriptions)
        clipboard.$items.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.mode == .clipboard else { return }
            self.updateResults(preserveSelection: true)
        }.store(in: &subscriptions)
        files.$results.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.mode == .root else { return }
            self.updateResults(preserveSelection: true)
        }.store(in: &subscriptions)
        files.$isSearching.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.mode == .root else { return }; self.render()
        }.store(in: &subscriptions)
        aliases.$aliases.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateResults(preserveSelection: false)
        }.store(in: &subscriptions)
        ai.$provider.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
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
            case 36, 76: self.performSelected(); return nil
            default: return event
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss(restoreFocus: false)
        }
    }

    private func buildInterface() {
        let content = NSView()
        if #available(macOS 26.0, *) {
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
            material.state = .active
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
        NSLayoutConstraint.activate([
            categoryWrapper.heightAnchor.constraint(equalToConstant: 22),
            aiButton.trailingAnchor.constraint(equalTo: categoryWrapper.trailingAnchor, constant: -12),
            aiButton.centerYAnchor.constraint(equalTo: categoryWrapper.centerYAnchor),
            category.trailingAnchor.constraint(lessThanOrEqualTo: aiButton.leadingAnchor, constant: -8),
            clearHistoryButton.trailingAnchor.constraint(equalTo: categoryWrapper.trailingAnchor, constant: -12),
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
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        index.refresh()
        mode = .root
        files.stop()
        input.stringValue = ""
        selection = 0
        message = nil
        updateResults()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let area = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - max(110, area.height * 0.2) - size.height))
        }
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
        panel.orderOut(nil)
        files.stop()
        if restoreFocus, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
    }
    func windowDidResignKey(_ notification: Notification) { if !isConfirmingClear { dismiss(restoreFocus: false) } }
    func controlTextDidChange(_ obj: Notification) {
        message = nil
        if mode == .root {
            if case .result = calculator.evaluate(input.stringValue) { files.stop() }
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
        let selectedID = preserveSelection && results.indices.contains(selection) ? results[selection].id : nil
        let query = input.stringValue
        switch mode {
        case .root:
            let appResults = index.applications.map(LauncherResult.application)
            let linkResults = quicklinks.links.map(LauncherResult.quicklink)
            let commands = LauncherCommand.allCases.map(LauncherResult.command)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let rankedApps = rank(appResults, query: "")
                results = Array(rankedApps.prefix(3)) + commands
            } else {
                results = Array(rank(appResults + linkResults + commands, query: query).prefix(12))
                // Indexed files enrich results without delaying or overtaking app matches.
                results += files.results.prefix(12).map(LauncherResult.file)
                switch calculator.evaluate(query) {
                case .result(let result): results.insert(.calculation(result), at: 0)
                case .failure(let error): message = error
                case .none, .incomplete: break
                }
            }
        case .quicklinks:
            results = rank(quicklinks.links.map(LauncherResult.quicklink), query: query)
        case .clipboard:
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = clipboard.items.filter { trimmed.isEmpty || $0.text.localizedCaseInsensitiveContains(trimmed) }.map(LauncherResult.clipboard)
        }
        selection = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? (preserveSelection ? min(selection, max(0, results.count - 1)) : 0)
        render()
        if !preserveSelection {
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
            default: name = ""
            }
            let appAliases: [String]
            if case .application(let app) = result, let alias = aliases.alias(for: app) { appAliases = [alias] }
            else { appAliases = [] }
            return AppSearchEntry(id: result.id, name: name, path: "", aliases: appAliases)
        }
        return search.ranked(query: query, entries: entries, usage: usage).compactMap { byID[$0.id] }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
        render()
        rows.layoutSubtreeIfNeeded()
        if rows.arrangedSubviews.indices.contains(selection) {
            rows.scrollToVisible(rows.arrangedSubviews[selection].frame)
        }
    }

    private func render() {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        category.stringValue = mode.title
        input.placeholderString = mode.placeholder
        searchIcon.isHidden = mode != .root
        backButton.isHidden = mode == .root
        clearHistoryButton.isHidden = mode != .clipboard
        clearHistoryButton.isEnabled = !clipboard.items.isEmpty
        aiButton.isHidden = mode != .root || input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        aiButton.title = "Ask \(ai.provider.title) ⇥"
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
                subtitle = command == .settings ? "Preferences and shortcuts" : "Command"
                action = "Open"
            case .quicklink(let link):
                icon = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
                title = link.name
                subtitle = link.target
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
            titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
            titleLabel.lineBreakMode = .byTruncatingTail
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 10)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingMiddle
            let hint = NSTextField(labelWithString: position == selection ? "↵" : "")
            hint.textColor = .secondaryLabelColor
            for view in [image, titleLabel, subtitleLabel, hint] { view.translatesAutoresizingMaskIntoConstraints = false; button.addSubview(view) }
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 44),
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
            button.setAccessibilityLabel("\(title), \(action)")
            button.invoke = { [weak self] in self?.selection = position; self?.performSelected() }
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
        let resultHeight: Int = results.isEmpty ? 48 : results.count * 46 - 2
        let errorHeight = message != nil && !results.isEmpty ? 42 : 0
        let documentHeight = CGFloat(resultHeight + errorHeight + 8)
        let visibleHeight = min(documentHeight, 330)
        rows.setFrameSize(NSSize(width: 560, height: documentHeight))
        scrollHeight.constant = visibleHeight
        let height = CGFloat(79) + visibleHeight
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - height, width: 560, height: height), display: true)
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
        case .quicklinks: return quicklinks.links.isEmpty ? "Add quicklinks in Settings" : "No quicklinks found"
        }
    }

    private func performSelected() {
        guard results.indices.contains(selection) else { return }
        switch results[selection] {
        case .command(let command):
            switch command {
            case .clipboard: enter(.clipboard)
            case .quicklinks: enter(.quicklinks)
            case .emoji: onEmoji?()
            case .settings: onSettings?()
            }
        case .quicklink(let link):
            guard let url = link.url, NSWorkspace.shared.open(url) else {
                message = "Couldn’t open this quicklink."; render(); return
            }
            usage[results[selection].id, default: 0] += 1
            UserDefaults.standard.set(usage, forKey: "usage")
            dismiss(restoreFocus: false)
        case .clipboard(let entry):
            clipboard.copy(entry)
            dismiss()
        case .file(let file):
            if NSWorkspace.shared.open(file.url) { dismiss(restoreFocus: false) }
            else { message = "Couldn’t open this file."; render() }
        case .calculation(let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.clipboard, forType: .string)
            dismiss()
        case .application(let app):
            index.launch(app) { [weak self] error in
                guard let self else { return }
                if let error { self.message = "Couldn’t open \(app.name): \(error.localizedDescription)"; self.render() }
                else {
                    self.usage[app.id, default: 0] += 1
                    UserDefaults.standard.set(self.usage, forKey: "usage")
                    self.dismiss(restoreFocus: false)
                }
            }
        }
    }
}
