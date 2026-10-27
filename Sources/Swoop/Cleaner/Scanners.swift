// SPDX-License-Identifier: MIT
import AppKit
import CryptoKit
import Security
import SwoopCore

/// A file or folder a module proposes to remove, with its "why this is safe" note.
struct CleanItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let size: Int64
    let group: String          // category / rule title
    let note: String
    var selected: Bool
    var detail: String = ""

    init(url: URL, size: Int64, group: String, note: String, selected: Bool, detail: String = "") {
        self.id = url.path
        self.url = url
        self.size = size
        self.group = group
        self.note = note
        self.selected = selected
        self.detail = detail
    }

    static func == (a: CleanItem, b: CleanItem) -> Bool { a.id == b.id && a.selected == b.selected }
    func hash(into h: inout Hasher) { h.combine(id) }
}

final class CancelToken {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

// MARK: - System junk

enum JunkScanner {
    static func list(_ dir: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] }

    /// Scans enabled rules. Runs on a background queue; `progress` gets the rule title.
    static func scan(rules: [JunkRule], cancel: CancelToken? = nil, progress: ((String) -> Void)? = nil) -> [CleanItem] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let preferred = Locale.preferredLanguages
        var out: [CleanItem] = []
        for rule in rules {
            if cancel?.cancelled == true { break }
            progress?(rule.title)
            for root in JunkRules.expandRoot(rule, home: home, list: list) {
                if rule.category == .languageFiles && !languageRootAllowed(root) { continue }
                for name in list(root) where rule.includes(name: name) {
                    if cancel?.cancelled == true { break }
                    if rule.category == .languageFiles && !LanguageFiles.shouldRemove(lproj: name, preferred: preferred) { continue }
                    let url = URL(fileURLWithPath: root).appendingPathComponent(name)
                    if rule.minAgeDays > 0,
                       let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                       Date().timeIntervalSince(m) < Double(rule.minAgeDays) * 86400 { continue }
                    let size = Sizer.size(of: url)
                    guard size > 0 || rule.category == .brokenDownloads else { continue }
                    out.append(CleanItem(url: url, size: size, group: rule.category.title,
                                         note: SafetyNotes.note(forRule: rule.id), selected: true, detail: rule.title))
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Language files: only third-party, non-App Store apps.
    static func languageRootAllowed(_ resources: String) -> Bool {
        let app = ((resources as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: app + "/Contents/_MASReceipt") { return false }
        if let id = Bundle(path: app)?.bundleIdentifier, id.hasPrefix("com.apple.") { return false }
        return FileManager.default.isWritableFile(atPath: resources)
    }

    static var enabledRules: [JunkRule] {
        let on = Set(Prefs.shared.enabledJunkRules)
        return JunkRules.all.filter { on.contains($0.id) }
    }
}

// MARK: - Large & old files

struct FoundFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64
    let lastUsed: Date?
}

enum LargeFileScanner {
    static func scan(root: URL, minBytes: Int64, cancel: CancelToken? = nil, progress: ((Int) -> Void)? = nil) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentAccessDateKey,
                                      .contentModificationDateKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        let skip = [NSHomeDirectory() + "/Library", NSHomeDirectory() + "/.Trash"]
        var out: [FoundFile] = []
        var n = 0
        for case let u as URL in e {
            n += 1
            if n % 2000 == 0 { progress?(n); if cancel?.cancelled == true { break } }
            if skip.contains(where: { u.path.hasPrefix($0) }) { e.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isPackage == true { e.skipDescendants(); continue }
            guard v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            guard size >= minBytes else { continue }
            out.append(FoundFile(path: u.path, size: size, lastUsed: v.contentAccessDate ?? v.contentModificationDate))
        }
        return out.sorted { $0.size > $1.size }
    }
}

// MARK: - Duplicates

enum DuplicateScanner {
    static func scan(folders: [URL], minBytes: Int64 = 100_000, cancel: CancelToken? = nil,
                     progress: ((String) -> Void)? = nil) -> [[FoundFile]] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        var files: [(path: String, size: Int64)] = []
        var dates: [String: Date] = [:]
        for f in folders {
            guard let e = FileManager.default.enumerator(at: f, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                         errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                if cancel?.cancelled == true { return [] }
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let s = Int64(v.fileSize ?? 0)
                if s >= minBytes { files.append((u.path, s)); dates[u.path] = v.creationDate ?? v.contentModificationDate }
            }
        }
        progress?("Comparing \(files.count) files…")
        // Pass 1: first 64 KB. Pass 2: whole file, only for files that still match.
        let partial = DuplicateGrouper.groups(files: files, minSize: minBytes) { hash($0, limit: 65_536) }
        var candidates: [(path: String, size: Int64)] = []
        let sizeOf = Dictionary(files.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        for g in partial { for p in g { candidates.append((p, sizeOf[p] ?? 0)) } }
        let full = DuplicateGrouper.groups(files: candidates, minSize: minBytes) { cancel?.cancelled == true ? nil : hash($0, limit: nil) }
        return full.map { g in
            g.map { FoundFile(path: $0, size: sizeOf[$0] ?? 0, lastUsed: dates[$0]) }
                .sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }   // oldest first = kept
        }.sorted { ($0.first?.size ?? 0) * Int64($0.count - 1) > ($1.first?.size ?? 0) * Int64($1.count - 1) }
    }

    static func hash(_ path: String, limit: Int?) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = CryptoKit.SHA256()
        var read = 0
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            if let l = limit, read + chunk.count > l {
                hasher.update(data: chunk.prefix(l - read))
                break
            }
            hasher.update(data: chunk)
            read += chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Uninstaller

struct UninstallTarget {
    let app: InstalledApp
    let identity: AppIdentity
    var items: [CleanItem]
}

enum Uninstaller {
    static func candidates() -> [InstalledApp] {
        Providers.shared.installedApps.filter { a in
            !a.path.hasPrefix("/System") && !(a.bundleID ?? "").hasPrefix("com.apple.")
                && a.bundleID != Bundle.main.bundleIdentifier && FileManager.default.fileExists(atPath: a.path)
        }
    }

    static func leftovers(for app: InstalledApp) -> UninstallTarget {
        let bundle = Bundle(path: app.path)
        let id = AppIdentity(bundleID: app.bundleID ?? "", name: app.name,
                             executableName: bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
        var items = [CleanItem(url: URL(fileURLWithPath: app.path), size: Sizer.size(of: URL(fileURLWithPath: app.path)),
                               group: "Application", note: "The app itself.", selected: true)]
        let home = NSHomeDirectory()
        guard !id.bundleID.isEmpty else { return UninstallTarget(app: app, identity: id, items: items) }
        for folder in LeftoverMatcher.libraryFolders {
            let dir = (home as NSString).appendingPathComponent(folder)
            for name in JunkScanner.list(dir) {
                guard let m = LeftoverMatcher.match(entryName: name, app: id) else { continue }
                let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
                items.append(CleanItem(url: u, size: Sizer.size(of: u), group: (folder as NSString).lastPathComponent,
                                       note: m == .bundleID ? SafetyNotes.leftover
                                           : "Named exactly like the app (\(app.name)). Check it isn't shared with another app before removing.",
                                       selected: m == .bundleID, detail: m == .bundleID ? "Matched by bundle ID" : "Matched by name"))
            }
        }
        return UninstallTarget(app: app, identity: id, items: items)
    }

    /// Library entries named after bundle IDs no installed app has.
    static func orphans(cancel: CancelToken? = nil) -> [CleanItem] {
        var installed = Set<String>()
        for a in Providers.scanApps() {
            if let b = a.bundleID?.lowercased() { installed.insert(b) }
            // helpers/extensions inside the app
            for sub in ["Contents/Library/LoginItems", "Contents/PlugIns", "Contents/Frameworks", "Contents/Helpers", "Contents/XPCServices"] {
                for n in JunkScanner.list((a.path as NSString).appendingPathComponent(sub)) {
                    if let b = Bundle(path: (a.path as NSString).appendingPathComponent(sub + "/" + n))?.bundleIdentifier {
                        installed.insert(b.lowercased())
                    }
                }
            }
        }
        let home = NSHomeDirectory()
        var out: [CleanItem] = []
        let folders = ["Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers",
                       "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Logs",
                       "Library/LaunchAgents"]
        for folder in folders {
            if cancel?.cancelled == true { break }
            let dir = (home as NSString).appendingPathComponent(folder)
            for name in JunkScanner.list(dir) where LeftoverMatcher.isOrphan(entryName: name, installed: installed) {
                // Ask Launch Services too: an app elsewhere on disk still counts as installed.
                if let bid = LeftoverMatcher.bundleID(fromEntryName: name),
                   NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil { continue }
                let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
                guard FileRemover.shared.verdict(u).isAllowed else { continue }
                out.append(CleanItem(url: u, size: Sizer.size(of: u), group: (folder as NSString).lastPathComponent,
                                     note: SafetyNotes.orphan, selected: false,
                                     detail: LeftoverMatcher.bundleID(fromEntryName: name) ?? name))
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

// MARK: - Code signing

enum CodeSign {
    /// "Developer ID: Name (TEAMID)" style summary, or nil when unsigned/invalid.
    static func signer(of path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let c = code else { return nil }
        guard SecStaticCodeCheckValidity(c, SecCSFlags(rawValue: 0), nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            return summary
        }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String { return "Team \(team)" }
        return nil
    }
}
