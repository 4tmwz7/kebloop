import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class CoalescedSnapshotWriter<Value: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let write: @Sendable (Value) -> Void
    private let lock = NSLock()
    private var pendingSnapshot: Value?
    private var drainScheduled = false

    init(queue: DispatchQueue, write: @escaping @Sendable (Value) -> Void) {
        self.queue = queue
        self.write = write
    }

    func enqueue(_ snapshot: Value) {
        lock.lock()
        pendingSnapshot = snapshot
        let shouldScheduleDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()

        guard shouldScheduleDrain else { return }
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            let snapshot = pendingSnapshot
            pendingSnapshot = nil
            if snapshot == nil { drainScheduled = false }
            lock.unlock()

            guard let snapshot else { return }
            write(snapshot)
        }
    }
}

enum ClipboardAttachmentKind: String, Codable, Hashable, Sendable {
    case image
    case richText
}

struct ClipboardAttachment: Codable, Hashable, Sendable {
    let fileName: String
    let pasteboardType: String
    let byteCount: Int
    let kind: ClipboardAttachmentKind
}

struct ClipboardEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let text: String
    let date: Date
    var isPinned: Bool
    let sourceBundleIdentifier: String?
    let imageAttachment: ClipboardAttachment?
    let richTextAttachment: ClipboardAttachment?

    init(
        id: String,
        text: String,
        date: Date,
        isPinned: Bool = false,
        sourceBundleIdentifier: String? = nil,
        imageAttachment: ClipboardAttachment? = nil,
        richTextAttachment: ClipboardAttachment? = nil
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.isPinned = isPinned
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.imageAttachment = imageAttachment
        self.richTextAttachment = richTextAttachment
    }

    var preview: String {
        let flattened = String(text.prefix(240)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !flattened.isEmpty { return flattened }
        if imageAttachment != nil && richTextAttachment != nil { return L("Image and rich text") }
        if imageAttachment != nil { return L("Image") }
        if richTextAttachment != nil { return L("Rich text") }
        return L("Clipboard item")
    }

    var searchableText: String { text.isEmpty ? preview : text }
    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || imageAttachment != nil || richTextAttachment != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, date, isPinned, sourceBundleIdentifier, imageAttachment, richTextAttachment
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        date = try values.decode(Date.self, forKey: .date)
        // The original text-only history did not have these fields.
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sourceBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
        imageAttachment = try values.decodeIfPresent(ClipboardAttachment.self, forKey: .imageAttachment)
        richTextAttachment = try values.decodeIfPresent(ClipboardAttachment.self, forKey: .richTextAttachment)
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardEntry] = []

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            // Content copied while recording is off must not enter history later.
            lastChangeCount = pasteboard.changeCount
            updatePolling()
        }
    }

    /// Pinned entries survive both age and count retention. They are included in Clear History.
    @Published var maximumItemCount: Int {
        didSet {
            let bounded = Self.boundedItemCount(maximumItemCount)
            guard bounded == maximumItemCount else { maximumItemCount = bounded; return }
            defaults.set(maximumItemCount, forKey: Self.maximumItemCountKey)
            enforceRetention()
            updatePolling()
        }
    }

    /// Zero keeps entries indefinitely. Pinned entries are exempt from age retention.
    @Published var maximumAgeDays: Int {
        didSet {
            let bounded = Self.boundedAgeDays(maximumAgeDays)
            guard bounded == maximumAgeDays else { maximumAgeDays = bounded; return }
            defaults.set(maximumAgeDays, forKey: Self.maximumAgeDaysKey)
            enforceRetention()
            updatePolling()
        }
    }

    @Published var excludedSourceBundleIDs: Set<String> {
        didSet {
            defaults.set(excludedSourceBundleIDs.sorted(), forKey: Self.excludedSourceBundleIDsKey)
        }
    }

    @Published private(set) var pauseUntil: Date? {
        didSet {
            if let pauseUntil { defaults.set(pauseUntil, forKey: Self.pauseUntilKey) }
            else { defaults.removeObject(forKey: Self.pauseUntilKey) }
            // Resuming never backfills the clipboard item that was present during a pause.
            lastChangeCount = pasteboard.changeCount
            updatePolling()
        }
    }

    private nonisolated static let enabledKey = "clipboardHistoryEnabled"
    private nonisolated static let maximumItemCountKey = "clipboardHistoryMaximumItemCount"
    private nonisolated static let maximumAgeDaysKey = "clipboardHistoryMaximumAgeDays"
    private nonisolated static let excludedSourceBundleIDsKey = "clipboardHistoryExcludedSourceBundleIDs"
    private nonisolated static let pauseUntilKey = "clipboardHistoryPauseUntil"
    private nonisolated static let defaultItemCount = 200
    private nonisolated static let maximumAllowedItemCount = 200
    private nonisolated static let maximumPinnedCount = 50
    private nonisolated static let textByteLimit = 100 * 1024
    private nonisolated static let maximumAttachmentBytesPerEntry = 5 * 1024 * 1024
    private nonisolated static let maximumAttachmentStorageBytes = 50 * 1024 * 1024
    // 250 retained entries, at six escaped bytes per text byte, plus metadata.
    private nonisolated static let maximumStorageBytes = 250 * (textByteLimit * 6 + 1_024)
    private nonisolated static let sensitiveMarkers = ["concealed", "transient", "autogenerated", "password"]
    private nonisolated static let imageTypes = [
        UTType.png.identifier,
        UTType.tiff.identifier,
        UTType.jpeg.identifier,
        "public.heic",
        "com.compuserve.gif"
    ]
    private nonisolated static let richTextTypes = ["public.rtf", "public.html"]

    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let storageURL: URL?
    private let attachmentDirectory: URL?
    private let storageQueue: DispatchQueue
    private let snapshotWriter: CoalescedSnapshotWriter<[ClipboardEntry]>
    private let attachmentReferences = ClipboardAttachmentReferenceRegistry()
    // NSPasteboard does not provide a stable writer bundle ID. This returns the app
    // frontmost when the polling timer notices a change, which may differ from the copier.
    private let sourceApplicationProvider: () -> String?
    private let thumbnailCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>(); cache.countLimit = 250; cache.totalCostLimit = 4 * 1024 * 1024; return cache
    }()
    private var thumbnailTasks: [String: Task<Data?, Never>] = [:]
    private var timer: Timer?
    private var lastChangeCount: Int
    private var revision = 0

    init(
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        storageURL: URL? = nil,
        sourceApplicationProvider: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.sourceApplicationProvider = sourceApplicationProvider
        let resolvedStorageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kebloop", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
        self.storageURL = resolvedStorageURL
        attachmentDirectory = resolvedStorageURL?.deletingPathExtension().appendingPathComponent("attachments", isDirectory: true)

        let storageQueue = DispatchQueue(label: "Kebloop.clipboard-storage", qos: .utility)
        self.storageQueue = storageQueue
        let targetURL = resolvedStorageURL
        let attachmentsURL = attachmentDirectory
        let references = attachmentReferences
        snapshotWriter = CoalescedSnapshotWriter(queue: storageQueue) { snapshot in
            guard let targetURL else { return }
            Self.write(snapshot, to: targetURL, attachmentDirectory: attachmentsURL, referenceRegistry: references)
        }

        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        maximumItemCount = Self.boundedItemCount(defaults.object(forKey: Self.maximumItemCountKey) as? Int ?? Self.defaultItemCount)
        maximumAgeDays = Self.boundedAgeDays(defaults.object(forKey: Self.maximumAgeDaysKey) as? Int ?? 0)
        excludedSourceBundleIDs = Set(defaults.stringArray(forKey: Self.excludedSourceBundleIDsKey) ?? [])
        if let savedPause = defaults.object(forKey: Self.pauseUntilKey) as? Date, savedPause > Date() {
            pauseUntil = savedPause
        } else {
            pauseUntil = nil
            defaults.removeObject(forKey: Self.pauseUntilKey)
        }

        // Taking this baseline excludes the clipboard contents that predate the store.
        lastChangeCount = pasteboard.changeCount
        load()
        updatePolling()
    }

    deinit { timer?.invalidate() }

    var isPaused: Bool { pauseUntil.map { $0 > Date() } ?? false }
    var isRecording: Bool { enabled && !isPaused }

    func pauseRecording(for interval: TimeInterval) {
        guard interval > 0 else { resumeRecording(); return }
        // Expose practical pauses without allowing a stale date to disable capture forever.
        pauseUntil = Date().addingTimeInterval(min(interval, 7 * 24 * 60 * 60))
    }

    func pauseRecording(until deadline: Date) {
        guard deadline > Date() else { resumeRecording(); return }
        pauseUntil = min(deadline, Date().addingTimeInterval(7 * 24 * 60 * 60))
    }

    func resumeRecording() {
        guard pauseUntil != nil else { lastChangeCount = pasteboard.changeCount; return }
        pauseUntil = nil
    }

    func clear() {
        thumbnailCache.removeAllObjects()
        // Clear History intentionally removes pinned entries and their attachment files too.
        items = []
        lastChangeCount = pasteboard.changeCount
        persist()
    }

    func clearUnpinned() {
        items.removeAll { !$0.isPinned }
        persist()
    }

    func remove(id: String) {
        thumbnailCache.removeAllObjects()
        items.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    func setPinned(_ pinned: Bool, for id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        if pinned && !items[index].isPinned && items.lazy.filter(\.isPinned).count >= Self.maximumPinnedCount {
            return false
        }
        guard items[index].isPinned != pinned else { return true }
        items[index].isPinned = pinned
        enforceRetention()
        persist()
        return true
    }

    @discardableResult
    func togglePin(id: String) -> Bool {
        guard let entry = items.first(where: { $0.id == id }) else { return false }
        return setPinned(!entry.isPinned, for: id)
    }

    func copy(_ entry: ClipboardEntry) {
        pasteboard.clearContents()
        if !entry.text.isEmpty { pasteboard.setString(entry.text, forType: .string) }
        if let richText = richTextData(for: entry) {
            pasteboard.setData(richText, forType: NSPasteboard.PasteboardType(rawValue: entry.richTextAttachment?.pasteboardType ?? "public.rtf"))
        }
        if let image = imageData(for: entry) {
            pasteboard.setData(image, forType: NSPasteboard.PasteboardType(rawValue: entry.imageAttachment?.pasteboardType ?? UTType.png.identifier))
        }
        lastChangeCount = pasteboard.changeCount
    }

    /// Loads image bytes only when a preview or copy action requests them.
    func imageData(for entry: ClipboardEntry) -> Data? {
        attachmentData(for: entry.imageAttachment, kind: .image)
    }

    /// Decodes a bounded thumbnail on a utility task, so opening history does not decode every image.
    func imageThumbnailData(for entry: ClipboardEntry, maximumPixelSize: Int = 96) async -> Data? {
        guard let url = imageURL(for: entry) else { return nil }
        let pixelLimit = min(max(maximumPixelSize, 1), 512)
        let key = url.lastPathComponent + ":" + String(pixelLimit)
        if let cached = thumbnailCache.object(forKey: key as NSString) { return cached as Data }
        if let pending = thumbnailTasks[key] { return await pending.value }
        let task = Task.detached(priority: .utility) { () -> Data? in
            guard let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelLimit
                  ] as CFDictionary) else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        thumbnailTasks[key] = task
        let data = await task.value
        thumbnailTasks[key] = nil
        if let data, items.contains(where: { $0.id == entry.id }) { thumbnailCache.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
        return data
    }

    /// Loads rich-text bytes only when a copy action requests them.
    func richTextData(for entry: ClipboardEntry) -> Data? {
        attachmentData(for: entry.richTextAttachment, kind: .richText)
    }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        attachmentURL(for: entry.imageAttachment, kind: .image)
    }

    func poll() {
        expirePauseIfNeeded()
        enforceRetention()
        guard enabled else { return }
        guard !isPaused else {
            // Ignore all changes while paused, including the one present at the deadline.
            lastChangeCount = pasteboard.changeCount
            return
        }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let types = pasteboard.types ?? []
        guard !containsSensitiveMarker(types) else { return }
        let sourceBundleIdentifier = sourceApplicationProvider()
        if let sourceBundleIdentifier, excludedSourceBundleIDs.contains(sourceBundleIdentifier) { return }

        // AppKit may synthesize plain text from an RTF item. Drop an oversized text
        // representation while still allowing its bounded rich/image payload through.
        let availableText = pasteboard.string(forType: .string) ?? ""
        let text = availableText.utf8.count <= Self.textByteLimit ? availableText : ""
        let image = firstPayload(for: Self.imageTypes, among: types)
        let richText = firstPayload(for: Self.richTextTypes, among: types)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil || richText != nil else { return }
        record(text: text, image: image, richText: richText, sourceBundleIdentifier: sourceBundleIdentifier)
    }

    private func record(text: String, image: (type: String, data: Data)?, richText: (type: String, data: Data)?, sourceBundleIdentifier: String?) {
        let existing = items.first(where: { !text.isEmpty && $0.text == text })
        let id = existing?.id ?? UUID().uuidString
        let oldAttachmentBytes = (existing?.imageAttachment?.byteCount ?? 0) + (existing?.richTextAttachment?.byteCount ?? 0)
        var totalAttachmentBytes = items.reduce(0) { $0 + ($1.imageAttachment?.byteCount ?? 0) + ($1.richTextAttachment?.byteCount ?? 0) }
        totalAttachmentBytes = max(0, totalAttachmentBytes - oldAttachmentBytes)

        var entryAttachmentBytes = 0
        var imageAttachment: ClipboardAttachment?
        var richTextAttachment: ClipboardAttachment?

        if let image, image.data.count <= Self.maximumAttachmentBytesPerEntry,
           totalAttachmentBytes + image.data.count <= Self.maximumAttachmentStorageBytes {
            imageAttachment = saveAttachment(image.data, pasteboardType: image.type, kind: .image)
            if imageAttachment != nil {
                entryAttachmentBytes += image.data.count
                totalAttachmentBytes += image.data.count
            }
        }

        if let richText,
           richText.data.count <= Self.maximumAttachmentBytesPerEntry - entryAttachmentBytes,
           totalAttachmentBytes + richText.data.count <= Self.maximumAttachmentStorageBytes {
            richTextAttachment = saveAttachment(richText.data, pasteboardType: richText.type, kind: .richText)
        }

        let entry = ClipboardEntry(
            id: id,
            text: text,
            date: Date(),
            isPinned: existing?.isPinned ?? false,
            sourceBundleIdentifier: sourceBundleIdentifier,
            imageAttachment: imageAttachment,
            richTextAttachment: richTextAttachment
        )
        guard entry.hasContent else { return }
        items.removeAll { $0.id == id }
        items.insert(entry, at: 0)
        enforceRetention()
        persist()
    }

    private func firstPayload(for acceptedTypes: [String], among pasteboardTypes: [NSPasteboard.PasteboardType]) -> (type: String, data: Data)? {
        for type in acceptedTypes where pasteboardTypes.contains(NSPasteboard.PasteboardType(rawValue: type)) {
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(rawValue: type)), !data.isEmpty else { continue }
            // Do not retain malformed or unbounded binary content.
            guard data.count <= Self.maximumAttachmentBytesPerEntry,
                  Self.isValidAttachmentData(data, kind: acceptedTypes == Self.imageTypes ? .image : .richText) else { continue }
            return (type, data)
        }
        return nil
    }

    private func saveAttachment(_ data: Data, pasteboardType: String, kind: ClipboardAttachmentKind) -> ClipboardAttachment? {
        guard let attachmentDirectory, data.count > 0 else { return nil }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: attachmentDirectory.path)
            let fileName = "clipboard-\(UUID().uuidString).bin"
            let finalURL = attachmentDirectory.appendingPathComponent(fileName)
            let temporaryURL = attachmentDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? manager.removeItem(at: temporaryURL) }
            guard manager.createFile(atPath: temporaryURL.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else { return nil }
            try manager.moveItem(at: temporaryURL, to: finalURL)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
            return ClipboardAttachment(fileName: fileName, pasteboardType: pasteboardType, byteCount: data.count, kind: kind)
        } catch {
            return nil
        }
    }

    private func attachmentData(for attachment: ClipboardAttachment?, kind: ClipboardAttachmentKind) -> Data? {
        guard let attachment, attachment.kind == kind, let url = attachmentURL(for: attachment, kind: kind),
              let data = try? Data(contentsOf: url), Self.isValidAttachmentData(data, kind: kind) else {
            if let attachment { discardInvalidAttachment(attachment, kind: kind) }
            return nil
        }
        return data
    }

    private func attachmentURL(for attachment: ClipboardAttachment?, kind: ClipboardAttachmentKind) -> URL? {
        guard let attachment, attachment.kind == kind, Self.isSafeAttachmentName(attachment.fileName),
              let attachmentDirectory else { return nil }
        return attachmentDirectory.appendingPathComponent(attachment.fileName, isDirectory: false)
    }

    private func discardInvalidAttachment(_ attachment: ClipboardAttachment, kind: ClipboardAttachmentKind) {
        guard let index = items.firstIndex(where: { $0.imageAttachment == attachment || $0.richTextAttachment == attachment }) else { return }
        if kind == .image { items[index] = replacing(items[index], imageAttachment: nil) }
        else { items[index] = replacing(items[index], richTextAttachment: nil) }
        if !items[index].hasContent { items.remove(at: index) }
        persist()
    }

    private func replacing(_ entry: ClipboardEntry, imageAttachment: ClipboardAttachment?) -> ClipboardEntry {
        ClipboardEntry(id: entry.id, text: entry.text, date: entry.date, isPinned: entry.isPinned,
                       sourceBundleIdentifier: entry.sourceBundleIdentifier, imageAttachment: imageAttachment,
                       richTextAttachment: entry.richTextAttachment)
    }

    private func replacing(_ entry: ClipboardEntry, richTextAttachment: ClipboardAttachment?) -> ClipboardEntry {
        ClipboardEntry(id: entry.id, text: entry.text, date: entry.date, isPinned: entry.isPinned,
                       sourceBundleIdentifier: entry.sourceBundleIdentifier, imageAttachment: entry.imageAttachment,
                       richTextAttachment: richTextAttachment)
    }

    private func containsSensitiveMarker(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { pasteboardType in
            let name = pasteboardType.rawValue.lowercased()
            return Self.sensitiveMarkers.contains(where: name.contains)
        }
    }

    private func expirePauseIfNeeded() {
        guard let pauseUntil, pauseUntil <= Date() else { return }
        self.pauseUntil = nil
    }

    private func enforceRetention() {
        let retained = Self.retainedEntries(items, maximumItemCount: maximumItemCount,
                                            maximumAgeDays: maximumAgeDays, now: Date())
        guard retained != items else { return }
        items = retained
        persist()
    }

    private func load() {
        guard let storageURL else { return }
        let attachmentDirectory = self.attachmentDirectory
        storageQueue.async { [weak self] in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: storageURL.path),
                  let fileSize = attributes[.size] as? Int,
                  fileSize <= Self.maximumStorageBytes,
                  let data = try? Data(contentsOf: storageURL),
                  let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else { return }
            let sanitized = Self.sanitized(decoded, attachmentDirectory: attachmentDirectory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == 0 else { return }
                // Retention can change while disk loading is in flight. Apply current settings
                // at publication time so a stale snapshot cannot restore newly expired items.
                let loaded = Self.retainedEntries(sanitized, maximumItemCount: self.maximumItemCount,
                                                  maximumAgeDays: self.maximumAgeDays, now: Date())
                self.items = loaded
                let references = self.attachmentReferences
                references.update(Self.referencedAttachmentNames(in: loaded))
                self.storageQueue.async {
                    Self.cleanupAttachments(in: attachmentDirectory, keeping: references.snapshot())
                }
                if loaded != decoded { self.persist() }
            }
        }
    }

    private func persist() {
        thumbnailCache.removeAllObjects()
        revision &+= 1
        attachmentReferences.update(Self.referencedAttachmentNames(in: items))
        guard storageURL != nil else { return }
        // Keep only the newest pending state so a burst cannot queue hundreds of full-history snapshots.
        snapshotWriter.enqueue(items)
    }

    private func updatePolling() {
        let shouldPoll = enabled || maximumAgeDays > 0 || pauseUntil != nil
        if shouldPoll {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.poll() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private nonisolated static func boundedItemCount(_ value: Int) -> Int {
        min(max(value, 1), maximumAllowedItemCount)
    }

    private nonisolated static func boundedAgeDays(_ value: Int) -> Int {
        min(max(value, 0), 3_650)
    }

    private nonisolated static func retainedEntries(_ entries: [ClipboardEntry], maximumItemCount: Int, maximumAgeDays: Int, now: Date) -> [ClipboardEntry] {
        var seenIDs = Set<String>()
        let ageCutoff = maximumAgeDays > 0 ? now.addingTimeInterval(-TimeInterval(maximumAgeDays) * 24 * 60 * 60) : nil
        let valid = entries.sorted { $0.date > $1.date }.filter { entry in
            guard entry.hasContent, entry.text.utf8.count <= textByteLimit,
                  seenIDs.insert(entry.id).inserted else { return false }
            return entry.isPinned || ageCutoff.map { entry.date >= $0 } ?? true
        }
        let pinned = valid.filter(\.isPinned)
        let unpinned = valid.filter { !$0.isPinned }.prefix(maximumItemCount)
        return (Array(pinned) + Array(unpinned)).sorted { $0.date > $1.date }
    }

    private nonisolated static func sanitized(_ entries: [ClipboardEntry], attachmentDirectory: URL?) -> [ClipboardEntry] {
        var remainingAttachmentBytes = maximumAttachmentStorageBytes
        return entries.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.date > $1.date
        }.compactMap { entry in
            guard entry.hasContent, entry.text.utf8.count <= textByteLimit else { return nil }
            let image = validatedAttachment(entry.imageAttachment, kind: .image, directory: attachmentDirectory,
                                             remainingBytes: &remainingAttachmentBytes)
            let richText = validatedAttachment(entry.richTextAttachment, kind: .richText, directory: attachmentDirectory,
                                               remainingBytes: &remainingAttachmentBytes)
            let result = ClipboardEntry(id: entry.id, text: entry.text, date: entry.date, isPinned: entry.isPinned,
                                        sourceBundleIdentifier: entry.sourceBundleIdentifier,
                                        imageAttachment: image, richTextAttachment: richText)
            return result.hasContent ? result : nil
        }
    }

    private nonisolated static func validatedAttachment(
        _ attachment: ClipboardAttachment?,
        kind: ClipboardAttachmentKind,
        directory: URL?,
        remainingBytes: inout Int
    ) -> ClipboardAttachment? {
        guard let attachment, attachment.kind == kind, isSafeAttachmentName(attachment.fileName),
              attachment.byteCount > 0, attachment.byteCount <= maximumAttachmentBytesPerEntry,
              attachment.byteCount <= remainingBytes,
              let directory else { return nil }
        let url = directory.appendingPathComponent(attachment.fileName, isDirectory: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size == attachment.byteCount,
              let data = try? Data(contentsOf: url), isValidAttachmentData(data, kind: kind) else { return nil }
        remainingBytes -= attachment.byteCount
        return attachment
    }

    private nonisolated static func isSafeAttachmentName(_ fileName: String) -> Bool {
        fileName == URL(fileURLWithPath: fileName).lastPathComponent
            && fileName.hasPrefix("clipboard-") && fileName.hasSuffix(".bin")
            && fileName.count < 100
    }

    private nonisolated static func isValidAttachmentData(_ data: Data, kind: ClipboardAttachmentKind) -> Bool {
        guard !data.isEmpty, data.count <= maximumAttachmentBytesPerEntry else { return false }
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
            return CGImageSourceGetStatus(source) == .statusComplete
        case .richText:
            let prefix = data.prefix(32)
            if prefix.starts(with: Data("{\\rtf".utf8)) { return true }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private nonisolated static func referencedAttachmentNames(in entries: [ClipboardEntry]) -> Set<String> {
        Set(entries.flatMap { [$0.imageAttachment?.fileName, $0.richTextAttachment?.fileName].compactMap { $0 } })
    }

    private nonisolated static func write(
        _ snapshot: [ClipboardEntry],
        to storageURL: URL,
        attachmentDirectory: URL?,
        referenceRegistry: ClipboardAttachmentReferenceRegistry
    ) {
        let manager = FileManager.default
        let directory = storageURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(snapshot)
            let temporary = directory.appendingPathComponent(".clipboard-\(UUID().uuidString).json")
            defer { try? manager.removeItem(at: temporary) }
            guard manager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else { return }
            if manager.fileExists(atPath: storageURL.path) {
                _ = try manager.replaceItemAt(storageURL, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: storageURL)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            cleanupAttachments(in: attachmentDirectory, keeping: referencedAttachmentNames(in: snapshot)
                .union(referenceRegistry.snapshot()))
        } catch {
            // Recording still works for this session if local storage is unavailable.
        }
    }

    private nonisolated static func cleanupAttachments(in directory: URL?, keeping references: Set<String>) {
        guard let directory, let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("clipboard-") && url.pathExtension == "bin" {
            if !references.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
    }
}

private final class ClipboardAttachmentReferenceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var names = Set<String>()

    func update(_ references: Set<String>) {
        lock.lock()
        names = references
        lock.unlock()
    }

    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}
