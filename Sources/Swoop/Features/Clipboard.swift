// SPDX-License-Identifier: MIT
import AppKit
import SwoopCore

/// Clipboard history: text, images and files. Local only (Application Support/Swoop),
/// skips concealed/transient pasteboard types and password managers.
final class ClipboardManager {
    static let shared = ClipboardManager()

    private var history: ClipboardHistory
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var ignoreChange: Int?

    private init() {
        history = JSONStore.load(ClipboardHistory.self, from: "clipboard.json") ?? ClipboardHistory()
    }

    func start() {
        timer?.invalidate()
        guard Prefs.shared.clipboardEnabled else { return }
        lastChange = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Our own writes (paste from history, calculator copy) aren't re-recorded.
    func ignoreNextChange() { ignoreChange = NSPasteboard.general.changeCount + 1 }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if ignoreChange == pb.changeCount { ignoreChange = nil; return }
        let types = (pb.types ?? []).map { $0.rawValue }
        let front = NSWorkspace.shared.frontmostApplication
        if ClipboardPrivacy.shouldIgnore(types: types, frontmostBundleID: front?.bundleIdentifier) { return }
        var entry: ClipboardEntry?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            entry = ClipboardEntry(kind: .files, filePaths: urls.map { $0.path }, sourceApp: front?.localizedName)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard s.utf8.count < 2_000_000 else { return }
            entry = ClipboardEntry(kind: .text, text: s, sourceApp: front?.localizedName)
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let png = Self.pngData(data) {
            let name = UUID().uuidString + ".png"
            try? png.write(to: AppPaths.clipboardImages.appendingPathComponent(name))
            entry = ClipboardEntry(kind: .image, imageFile: name, sourceApp: front?.localizedName)
        }
        guard let e = entry else { return }
        history.retentionDays = Prefs.shared.clipboardRetentionDays
        let dropped = history.add(e)
        cleanup(dropped)
        save()
    }

    static func pngData(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func cleanup(_ dropped: [ClipboardEntry]) {
        for d in dropped where d.kind == .image {
            if let f = d.imageFile { try? FileManager.default.removeItem(at: AppPaths.clipboardImages.appendingPathComponent(f)) }
        }
    }

    private func save() { JSONStore.save(history, to: "clipboard.json") }

    func togglePin(_ id: UUID) { history.togglePin(id); save() }

    func clearAll() { cleanup(history.clearUnpinned()); save() }

    var count: Int { history.entries.count }

    func items(matching q: String) -> [LauncherItem] {
        let df = RelativeDateTimeFormatter()
        df.unitsStyle = .short
        return history.search(q).map { e in
            let imagePath = e.imageFile.map { AppPaths.clipboardImages.appendingPathComponent($0).path }
            let icon: ItemIcon
            switch e.kind {
            case .text: icon = .symbol(e.pinned ? "pin.fill" : "doc.plaintext")
            case .image: icon = imagePath.flatMap { NSImage(contentsOfFile: $0) }.map { .image($0) } ?? .symbol("photo")
            case .files: icon = e.filePaths?.first.map { .file($0) } ?? .symbol("doc")
            }
            let when = df.localizedString(for: e.date, relativeTo: Date())
            return LauncherItem(
                id: e.id.uuidString, title: e.title,
                subtitle: [e.sourceApp, when].compactMap { $0 }.joined(separator: " · "),
                icon: icon, accessory: e.pinned ? "Pinned" : nil, section: e.pinned ? "Pinned" : "Recent",
                actions: [
                    LauncherAction(title: "Paste", symbol: "doc.on.clipboard") { self.paste(e) },
                    LauncherAction(title: "Copy to Clipboard", symbol: "doc.on.doc", shortcut: "⌘↩", closes: false) {
                        self.write(e)
                        LauncherController.shared.model.flash("Copied")
                    },
                    LauncherAction(title: e.pinned ? "Unpin" : "Pin", symbol: "pin", shortcut: "⌘P", closes: false) {
                        self.togglePin(e.id)
                        LauncherController.shared.model.refresh()
                    },
                    LauncherAction(title: "Delete Entry", symbol: "trash", closes: false) {
                        if let removed = self.history.remove(e.id) { self.cleanup([removed]) }
                        self.save()
                        LauncherController.shared.model.refresh()
                    },
                    LauncherAction(title: "Clear History (keeps pinned)", symbol: "trash.slash", closes: false) {
                        if Actions.confirm("Clear clipboard history?", "Pinned entries are kept.", ok: "Clear", destructive: true) {
                            self.clearAll()
                            LauncherController.shared.model.refresh()
                        }
                    },
                ],
                preview: e.kind == .text ? String((e.text ?? "").prefix(4000)) : e.filePaths?.joined(separator: "\n"),
                previewImage: imagePath)
        }
    }

    private func write(_ e: ClipboardEntry) {
        let pb = NSPasteboard.general
        ignoreNextChange()
        pb.clearContents()
        switch e.kind {
        case .text: pb.setString(e.text ?? "", forType: .string)
        case .image:
            if let f = e.imageFile, let d = try? Data(contentsOf: AppPaths.clipboardImages.appendingPathComponent(f)) {
                pb.setData(d, forType: .png)
            }
        case .files:
            pb.writeObjects((e.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        }
    }

    func paste(_ e: ClipboardEntry) {
        write(e)
        Actions.pasteFrontmost()
    }
}
