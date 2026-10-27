// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Ranking

/// Frequency + recency ranking ("frecency") for launcher results, plus favourites.
public struct UsageRanker: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var count: Int
        public var lastUsed: Date
    }

    public var entries: [String: Entry] = [:]
    public var favourites: [String] = []

    public init() {}

    public mutating func recordUse(_ id: String, at date: Date = Date()) {
        var e = entries[id] ?? Entry(count: 0, lastUsed: date)
        e.count += 1
        e.lastUsed = date
        entries[id] = e
    }

    public mutating func toggleFavourite(_ id: String) {
        if let i = favourites.firstIndex(of: id) { favourites.remove(at: i) } else { favourites.append(id) }
    }

    public func isFavourite(_ id: String) -> Bool { favourites.contains(id) }

    /// A bonus added to the fuzzy score: log-scaled use count, decayed by a 2-week half-life.
    public func bonus(for id: String, now: Date = Date()) -> Double {
        var b = isFavourite(id) ? 6.0 : 0.0
        if let e = entries[id] {
            let days = max(0, now.timeIntervalSince(e.lastUsed) / 86400)
            let decay = pow(0.5, days / 14)
            b += log2(Double(e.count) + 1) * 2.0 * decay
        }
        return b
    }

    /// Most used ids, best first (for the empty-query list).
    public func top(_ n: Int, now: Date = Date()) -> [String] {
        entries.keys.sorted { bonus(for: $0, now: now) > bonus(for: $1, now: now) }.prefix(n).map { $0 }
    }
}

// MARK: - Clipboard history

public struct ClipboardEntry: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case text, image, files }

    public var id: UUID
    public var kind: Kind
    public var text: String?          // .text
    public var imageFile: String?     // .image: file name in the images folder
    public var filePaths: [String]?   // .files
    public var date: Date
    public var pinned: Bool
    public var sourceApp: String?

    public init(id: UUID = UUID(), kind: Kind, text: String? = nil, imageFile: String? = nil,
                filePaths: [String]? = nil, date: Date = Date(), pinned: Bool = false, sourceApp: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFile = imageFile
        self.filePaths = filePaths
        self.date = date
        self.pinned = pinned
        self.sourceApp = sourceApp
    }

    public var title: String {
        switch kind {
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
            return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
        case .image: return "Image"
        case .files:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names.count) files: " + names.prefix(3).joined(separator: ", ")
        }
    }

    /// Same content (ignores date/pin), used to de-duplicate.
    public func sameContent(as o: ClipboardEntry) -> Bool {
        kind == o.kind && text == o.text && filePaths == o.filePaths && (kind != .image || imageFile == o.imageFile)
    }
}

public struct ClipboardHistory: Codable, Equatable {
    public private(set) var entries: [ClipboardEntry] = []
    public var maxEntries: Int
    public var retentionDays: Int

    public init(maxEntries: Int = 300, retentionDays: Int = 30) {
        self.maxEntries = maxEntries
        self.retentionDays = retentionDays
    }

    /// Adds to the top. A duplicate moves to the top (keeping its pin). Returns entries
    /// that were dropped (so their image files can be deleted).
    @discardableResult
    public mutating func add(_ e: ClipboardEntry, now: Date = Date()) -> [ClipboardEntry] {
        var entry = e
        if let i = entries.firstIndex(where: { $0.sameContent(as: e) }) {
            entry.pinned = entries[i].pinned
            entry.id = entries[i].id
            entries.remove(at: i)
        }
        entries.insert(entry, at: 0)
        return prune(now: now)
    }

    @discardableResult
    public mutating func prune(now: Date = Date()) -> [ClipboardEntry] {
        var dropped: [ClipboardEntry] = []
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        entries.removeAll { e in
            let old = !e.pinned && retentionDays > 0 && e.date < cutoff
            if old { dropped.append(e) }
            return old
        }
        while entries.filter({ !$0.pinned }).count > maxEntries, let i = entries.lastIndex(where: { !$0.pinned }) {
            dropped.append(entries.remove(at: i))
        }
        return dropped
    }

    public mutating func togglePin(_ id: UUID) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].pinned.toggle() }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> ClipboardEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: i)
    }

    @discardableResult
    public mutating func clearUnpinned() -> [ClipboardEntry] {
        let dropped = entries.filter { !$0.pinned }
        entries.removeAll { !$0.pinned }
        return dropped
    }

    /// Pinned first, then newest; filtered by fuzzy match on the text / file names.
    public func search(_ query: String) -> [ClipboardEntry] {
        let sorted = entries.filter { $0.pinned } + entries.filter { !$0.pinned }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return sorted }
        return sorted.filter { e in
            let hay = e.kind == .files ? (e.filePaths ?? []).joined(separator: " ") : (e.text ?? e.title)
            return hay.localizedCaseInsensitiveContains(q) || FuzzyMatcher.match(q, in: String(hay.prefix(200))) != nil
        }
    }
}

/// Pasteboard types that mean "don't record me" (nspasteboard.org conventions), and
/// password managers whose copies are never recorded.
public enum ClipboardPrivacy {
    public static let ignoredTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "com.typeit4me.clipping", "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]

    public static let ignoredApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane", "com.callpod.keepermac.lite",
        "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop", "com.nordpass.macos.NordPass", "com.proton.pass",
        "com.keepersecurity.keeper",
    ]

    public static func shouldIgnore(types: [String], frontmostBundleID: String?) -> Bool {
        if let f = frontmostBundleID, ignoredApps.contains(f) { return true }
        return types.contains { ignoredTypes.contains($0) }
    }
}

// MARK: - Files

public enum FileKind: String, CaseIterable, Identifiable {
    case all, video, audio, image, archive, diskImage, document, other
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All kinds"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .image: return "Images"
        case .archive: return "Archives"
        case .diskImage: return "Disk images & installers"
        case .document: return "Documents"
        case .other: return "Other"
        }
    }

    public static func of(path: String) -> FileKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "flv", "mpg", "mpeg", "3gp", "prores": return .video
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg", "opus", "caf", "alac": return .audio
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "raw", "cr2", "nef", "arw", "dng", "psd", "webp", "bmp":
            return .image
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "cab": return .archive
        case "dmg", "iso", "img", "pkg", "mpkg", "sparseimage", "sparsebundle", "vmdk", "vdi", "qcow2", "ipsw", "xip":
            return .diskImage
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "rtf", "csv", "epub", "md":
            return .document
        default: return .other
        }
    }
}

public struct LargeFileFilter: Equatable {
    public var minBytes: Int64
    public var olderThanDays: Int   // 0 = any age (by last access, falling back to modification)
    public var kind: FileKind

    public init(minBytes: Int64 = 100_000_000, olderThanDays: Int = 0, kind: FileKind = .all) {
        self.minBytes = minBytes
        self.olderThanDays = olderThanDays
        self.kind = kind
    }

    public func matches(path: String, size: Int64, lastUsed: Date?, now: Date = Date()) -> Bool {
        guard size >= minBytes else { return false }
        if kind != .all && FileKind.of(path: path) != kind { return false }
        if olderThanDays > 0 {
            guard let d = lastUsed else { return true }
            if now.timeIntervalSince(d) < Double(olderThanDays) * 86400 { return false }
        }
        return true
    }
}

/// Groups files with identical content. Files are first grouped by size; only same-size
/// files are hashed (`hash` returns nil for unreadable files, which are skipped).
public enum DuplicateGrouper {
    public static func groups(files: [(path: String, size: Int64)], minSize: Int64 = 1,
                              hash: (String) -> String?) -> [[String]] {
        var bySize: [Int64: [String]] = [:]
        for f in files where f.size >= minSize { bySize[f.size, default: []].append(f.path) }
        var out: [[String]] = []
        for (_, paths) in bySize where paths.count > 1 {
            var byHash: [String: [String]] = [:]
            for p in paths { if let h = hash(p) { byHash[h, default: []].append(p) } }
            for (_, g) in byHash where g.count > 1 { out.append(g.sorted()) }
        }
        return out.sorted { $0[0] < $1[0] }
    }
}

// MARK: - launchctl

public enum LaunchctlParser {
    /// Parses `launchctl print-disabled gui/<uid>` output into label → disabled.
    /// Lines look like:  "com.foo.agent" => disabled   (or => true / => enabled / => false)
    public static func disabledServices(_ output: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let arrow = t.range(of: "=>") else { continue }
            let label = t[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = t[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            if state.hasPrefix("disabled") || state.hasPrefix("true") { out[label] = true }
            else if state.hasPrefix("enabled") || state.hasPrefix("false") { out[label] = false }
        }
        return out
    }
}

// MARK: - Formatting

public enum Bytes {
    public static func format(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(n) B" }
        return String(format: v >= 100 ? "%.0f" : "%.1f", v) + " " + units[i]
    }
}
