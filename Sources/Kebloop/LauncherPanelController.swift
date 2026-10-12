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

private enum LauncherResult {
    case application(IndexedApplication)
    case calculation(CalculationResult)
    var id: String {
        switch self {
        case .application(let app): return app.id
        case .calculation: return "calculator"
        }
    }
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
    private let index: ApplicationIndex
    private let search = AppSearch()
    private let calculator = CalculatorEngine()
    private let panel: LauncherPanel
    private let input = SearchField()
    private let rows = NSStackView()
    private let category = NSTextField(labelWithString: "APPLICATIONS")
    private var results: [LauncherResult] = []
    private var selection = 0
    private var usage = UserDefaults.standard.dictionary(forKey: "usage") as? [String: Int] ?? [:]
    private var previousApp: NSRunningApplication?
    private var subscriptions = Set<AnyCancellable>()
    private var keyboardMonitor: Any?
    private var outsideMonitor: Any?
    private var message: String?

    init(index: ApplicationIndex) {
        self.index = index
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityLabel("Kebloop launcher")
        buildInterface()
        index.$applications.dropFirst().sink { [weak self] _ in self?.updateResults(preserveSelection: true) }.store(in: &subscriptions)
        index.$iconRevision.dropFirst().throttle(for: .milliseconds(30), scheduler: DispatchQueue.main, latest: true).sink { [weak self] _ in
            guard let self, self.panel.isVisible else { return }; self.render()
        }.store(in: &subscriptions)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self.onSettings?(); return nil
            }
            switch event.keyCode {
            case 53: self.dismiss(); return nil
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
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        input.placeholderString = "Search apps or calculate…"
        input.font = .systemFont(ofSize: 19, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.setAccessibilityLabel("Search apps or calculate")
        input.cell?.isScrollable = true
        for view in [icon, input] { view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view) }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 56),
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
        NSLayoutConstraint.activate([
            categoryWrapper.heightAnchor.constraint(equalToConstant: 22),
            category.leadingAnchor.constraint(equalTo: categoryWrapper.leadingAnchor, constant: 16),
            category.centerYAnchor.constraint(equalTo: categoryWrapper.centerYAnchor)
        ])
        container.addArrangedSubview(categoryWrapper)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 8, right: 6)
        container.addArrangedSubview(rows)
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

    func toggle() { panel.isVisible ? dismiss() : show() }
    func show() {
        if !panel.isVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        index.refresh()
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
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(input)
    }

    func dismiss(restoreFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if restoreFocus, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
    }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }
    func controlTextDidChange(_ obj: Notification) { message = nil; updateResults() }

    private func updateResults(preserveSelection: Bool = false) {
        let selectedID = preserveSelection && results.indices.contains(selection) ? results[selection].id : nil
        let query = input.stringValue
        let entries = search.ranked(query: query, entries: index.applications.map(\.searchEntry), usage: usage)
        let byID = Dictionary(uniqueKeysWithValues: index.applications.map { ($0.id, $0) })
        results = entries.prefix(7).compactMap { byID[$0.id].map(LauncherResult.application) }
        switch calculator.evaluate(query) {
        case .result(let result): results.insert(.calculation(result), at: 0)
        case .failure(let error): message = error
        case .none, .incomplete: break
        }
        results = Array(results.prefix(7))
        selection = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        render()
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
        render()
    }

    private func render() {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        category.stringValue = input.stringValue.isEmpty ? "Applications" : "Results"
        if results.isEmpty {
            let label = NSTextField(labelWithString: message ?? (index.isRefreshing ? "Finding your apps…" : "No results"))
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
                hint.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10),
                hint.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
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
        let height = CGFloat(87 + resultHeight + errorHeight)
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - height, width: 560, height: height), display: true)
    }

    private func performSelected() {
        guard results.indices.contains(selection) else { return }
        switch results[selection] {
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
