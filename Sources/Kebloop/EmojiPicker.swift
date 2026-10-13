import AppKit
import SwiftUI
import KebloopCore

private final class EmojiPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class EmojiPickerModel: ObservableObject {
    @Published var query = "" {
        didSet {
            selection = 0
            refreshResults()
        }
    }
    @Published var selectedCategory = "All" {
        didSet {
            selection = 0
            refreshResults()
        }
    }
    @Published private(set) var recentSymbols: [String] = []
    @Published private(set) var selection = 0
    @Published private(set) var results: [EmojiEntry] = []

    let categories = ["All", "Smileys", "People", "Animals", "Nature", "Food", "Travel", "Places", "Activities", "Objects", "Symbols", "Flags"]
    private let recentsKey = "emojiPicker.recent"

    init() {
        recentSymbols = Array((UserDefaults.standard.stringArray(forKey: recentsKey) ?? []).prefix(24))
        refreshResults()
    }

    private func refreshResults() {
        let matches = EmojiCatalog.search(query)
        results = selectedCategory == "All" ? matches : matches.filter { $0.category == selectedCategory }
    }

    var selectedEntry: EmojiEntry? {
        guard results.indices.contains(selection) else { return nil }
        return results[selection]
    }

    var recentEntries: [EmojiEntry] {
        recentSymbols.compactMap(EmojiCatalog.entry(forSymbol:))
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(results.count - 1, max(0, selection + delta))
    }

    func select(_ entry: EmojiEntry) {
        recentSymbols.removeAll { $0 == entry.symbol }
        recentSymbols.insert(entry.symbol, at: 0)
        recentSymbols = Array(recentSymbols.prefix(24))
        UserDefaults.standard.set(recentSymbols, forKey: recentsKey)
    }

    func index(of entry: EmojiEntry) -> Int? {
        results.firstIndex(where: { $0.id == entry.id })
    }
}

private struct EmojiPickerView: View {
    @ObservedObject var model: EmojiPickerModel
    let choose: (EmojiEntry) -> Void
    let copyOnly: (EmojiEntry) -> Void
    let close: () -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = Array(repeating: GridItem(.flexible(minimum: 32), spacing: 4), count: 8)

    private var groups: [(String, [EmojiEntry])] {
        let categoryOrder = Array(model.categories.dropFirst())
        let grouped = Dictionary(grouping: model.results, by: \.category)
        return categoryOrder.compactMap { category in
            guard let entries = grouped[category], !entries.isEmpty else { return nil }
            return (category, entries)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L("Search emoji"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
                    .accessibilityLabel(L("Search emoji"))
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Clear search"))
                }
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close emoji picker"))
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            HStack {
                Text(L("Return pastes · Command-Return copies"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Copy")) {
                    if let entry = model.selectedEntry { copyOnly(entry) }
                }.disabled(model.selectedEntry == nil)
            }.padding(.horizontal, 16).padding(.bottom, 8)
            Divider().opacity(0.55)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.categories, id: \.self) { category in
                        Button {
                            model.selectedCategory = category
                            searchFocused = true
                        } label: {
                            Text(category)
                                .font(.system(size: 11, weight: model.selectedCategory == category ? .semibold : .regular))
                                .foregroundStyle(model.selectedCategory == category ? Color.primary : Color.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background {
                                    Capsule().fill(model.selectedCategory == category ? Color.accentColor.opacity(0.16) : Color.clear)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(model.selectedCategory == category ? "Selected" : "")
                        .accessibilityAddTraits(model.selectedCategory == category ? .isSelected : [])
                        .accessibilityHint(L("Filters emoji by category."))
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 38)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        if model.query.isEmpty, model.selectedCategory == "All", !model.recentEntries.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                sectionTitle("RECENT")
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                                    ForEach(model.recentEntries) { entry in
                                        emojiButton(entry)
                                    }
                                }
                            }
                        }

                        if model.results.isEmpty {
                            ContentUnavailableView.search(text: model.query)
                                .frame(maxWidth: .infinity, minHeight: 180)
                        } else {
                            ForEach(groups, id: \.0) { category, entries in
                                VStack(alignment: .leading, spacing: 6) {
                                    sectionTitle(category.uppercased())
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                                        ForEach(entries) { entry in
                                            emojiButton(entry)
                                                .id(entry.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: model.selectedEntry?.id) { _, selectedID in
                    guard let selectedID else { return }
                    if reduceMotion { proxy.scrollTo(selectedID, anchor: .center) }
                    else { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selectedID, anchor: .center) } }
                }
            }
        }
        .frame(width: 468, height: 492)
        .background(Color.clear)
        .onAppear { searchFocused = true }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func emojiButton(_ entry: EmojiEntry) -> some View {
        let isSelected = model.selectedEntry?.id == entry.id
        return Button {
            choose(entry)
        } label: {
            Text(entry.symbol)
                .font(.system(size: 23))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("\(entry.name) — \(entry.symbol)")
        .accessibilityLabel("\(entry.name), \(entry.symbol)")
        .accessibilityValue(isSelected ? "Selected for pasting" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(L("Press Return or click to paste this emoji. Command-Return copies."))
    }
}

/// A compact native emoji picker. The owner should keep this controller alive while it is in use.
@MainActor
public final class EmojiPickerController: NSWindowController, NSWindowDelegate {
    private let pickerModel = EmojiPickerModel()
    private let onCopy: (() -> Void)?
    private let onDismiss: (() -> Void)?
    private let onPaste: (() -> Void)?
    private var keyboardMonitor: Any?
    private var outsideMonitor: Any?

    public init(onCopy: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil, onPaste: (() -> Void)? = nil) {
        self.onCopy = onCopy
        self.onPaste = onPaste
        self.onDismiss = onDismiss ?? onCopy
        let panel = EmojiPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 468, height: 492),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        panel.isOpaque = reduceTransparency
        panel.backgroundColor = reduceTransparency ? .windowBackgroundColor : .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityLabel(L("Emoji picker"))
        installView(in: panel)

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if (self.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            if event.modifierFlags.contains([.control, .option]) { return event }
            switch event.keyCode {
            case 53:
                self.dismiss()
                return nil
            case 125:
                if event.modifierFlags.contains([.control, .option]) { return event }
                self.pickerModel.moveSelection(by: 8)
                return nil
            case 126:
                if event.modifierFlags.contains([.control, .option]) { return event }
                self.pickerModel.moveSelection(by: -8)
                return nil
            case 124:
                if event.modifierFlags.contains([.control, .option]) { return event }
                self.pickerModel.moveSelection(by: 1)
                return nil
            case 123:
                if event.modifierFlags.contains([.control, .option]) { return event }
                self.pickerModel.moveSelection(by: -1)
                return nil
            case 36, 76:
                if let entry = self.pickerModel.selectedEntry { self.copy(entry, paste: !event.modifierFlags.contains(.command)) }
                return nil
            default:
                return event
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    }

    public func show() {
        guard let window else { return }
        pickerModel.query = ""
        pickerModel.selectedCategory = "All"
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.maxY - max(100, area.height * 0.18) - window.frame.height))
        }
        window.orderFrontRegardless()
        window.makeKey()
    }

    public func dismiss() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        onDismiss?()
    }

    public func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func copy(_ entry: EmojiEntry, paste: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.symbol, forType: .string)
        pickerModel.select(entry)
        if let window, window.isVisible { window.orderOut(nil) }
        if paste, let onPaste { onPaste() } else { onCopy?() }
    }

    private func installView(in panel: NSPanel) {
        let hosting = NSHostingView(rootView: EmojiPickerView(model: pickerModel, choose: { [weak self] entry in
            self?.copy(entry)
        }, copyOnly: { [weak self] entry in self?.copy(entry, paste: false) }, close: { [weak self] in self?.dismiss() }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 18
            glass.wantsLayer = true
            glass.layer?.cornerRadius = glass.cornerRadius
            glass.layer?.masksToBounds = true
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 18
            material.layer?.masksToBounds = true
            panel.contentView = material
            material.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: material.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
        }
    }
}
