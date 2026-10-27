// SPDX-License-Identifier: MIT
//
// Downloads the enabled filter lists straight from their maintainers (with mirrors),
// verifies each one (ListIntegrity), keeps the last good copy when an update looks wrong,
// and compiles everything into the DNS index, the Safari content-blocker chunks and the
// Chrome/Firefox extension rules. Runs at launch, then checks hourly and refreshes each
// list about once a day (never more often than every 6 hours).
import AppKit
import Foundation
import ShieldCore

final class ShieldListManager: ObservableObject {
    @Published private(set) var records: [String: ListRecord] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var isUpdating = false
    @Published private(set) var report: CompileReport?
    @Published private(set) var compiledAt: Date?

    var onCompiled: ((Data) -> Void)?

    private var enabled: [String] = []
    private var timer: Timer?
    private let work = DispatchQueue(label: "swoop.shield.lists", qos: .utility)
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "Swoop-Shield/0.2 (+https://swoopkey.com)"]
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()

    static var listsDir: URL {
        let u = ShieldController.dir.appendingPathComponent("lists", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static var recordsURL: URL { listsDir.appendingPathComponent("records.json") }
    static var indexURL: URL { ShieldController.dir.appendingPathComponent("shield.swsh") }
    static var browserExtensionDir: URL { ShieldController.dir.appendingPathComponent("BrowserExtension", isDirectory: true) }

    func start(enabledIDs: [String]) {
        enabled = enabledIDs
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: ShieldListManager.recordsURL), let r = try? d.decode([String: ListRecord].self, from: data) {
            records = r
        }
        compiledAt = (try? ShieldIndex(contentsOf: ShieldListManager.indexURL, verifyChecksum: false))?.createdAt
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.updateIfDue() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if compiledAt == nil { update(force: false) } else { updateIfDue() }
    }

    func setEnabled(_ ids: [String]) {
        enabled = ids
        update(force: false)   // downloads anything new, recompiles without removed lists
    }

    func updateIfDue() {
        let now = Date()
        let due = enabled.contains { id in records[id].map { ListIntegrity.nextUpdate(after: $0) <= now } ?? true }
        if due { update(force: false) }
    }

    /// `force` re-downloads every enabled list now ("Update lists" button / launcher command).
    func update(force: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        let ids = enabled
        let current = records
        work.async { [weak self] in
            guard let self = self else { return }
            var recs = current
            var errs: [String: String] = [:]
            let now = Date()
            for id in ids {
                guard let src = FilterListCatalog.source(id: id) else { continue }
                let local = ShieldListManager.listsDir.appendingPathComponent("\(id).txt")
                let due = force || recs[id].map { ListIntegrity.nextUpdate(after: $0) <= now } ?? true
                    || !FileManager.default.fileExists(atPath: local.path)
                guard due else { continue }
                var lastError = "no mirror answered"
                for url in src.urls {
                    guard let (data, finalURL) = self.download(url) else { lastError = "couldn't download from \(URL(string: url)?.host ?? url)"; continue }
                    switch ListIntegrity.verify(data: data, source: src, fetchedFrom: finalURL, previous: recs[id]) {
                    case .success(let (rec, _)):
                        try? data.write(to: local, options: .atomic)
                        recs[id] = rec
                        lastError = ""
                    case .failure(let e):
                        lastError = e.description
                    }
                    if lastError.isEmpty { break }
                }
                if !lastError.isEmpty { errs[id] = lastError + (recs[id] != nil ? " (using the copy from \(Self.ago(recs[id]!.fetchedAt)))" : "") }
            }
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
            try? enc.encode(recs).write(to: ShieldListManager.recordsURL, options: .atomic)
            let compiled = self.compile(ids: ids)
            DispatchQueue.main.async {
                self.records = recs
                self.errors = errs
                self.isUpdating = false
                if let (index, report) = compiled {
                    self.report = report
                    self.compiledAt = Date()
                    self.onCompiled?(index)
                }
            }
        }
    }

    private static func ago(_ d: Date) -> String { RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()) }

    private func download(_ url: String) -> (Data, String)? {
        guard let u = URL(string: url) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        let out = Box<(Data, String)?>(nil)
        session.dataTask(with: u) { data, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200, let d = data { out.value = (d, h.url?.absoluteString ?? url) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 90)
        return out.value
    }

    /// Compiles every enabled list we have a verified copy of and writes the outputs.
    private func compile(ids: [String]) -> (Data, CompileReport)? {
        var texts: [ListText] = []
        for id in ids {
            guard let src = FilterListCatalog.source(id: id),
                  let t = try? String(contentsOf: ShieldListManager.listsDir.appendingPathComponent("\(id).txt"), encoding: .utf8) else { continue }
            texts.append(ListText(source: src, text: t))
        }
        guard let c = try? ShieldCompiler.compile(texts, options: .init(buildBrowser: true, safariChunkCount: ShieldController.safariBlockerCount)) else { return nil }
        do { try c.index.write(to: ShieldListManager.indexURL, options: .atomic) } catch { return nil }
        if let g = ShieldController.groupDir, let s = c.safari {
            let dir = g.appendingPathComponent("safari", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, chunk) in s.chunks.enumerated() {
                try? SafariConverter.json(chunk).write(to: dir.appendingPathComponent("blocker-\(i + 1).json"), options: .atomic)
            }
            if let cos = c.cosmetic { try? cos.json().write(to: g.appendingPathComponent("cosmetic.json"), options: .atomic) }
        }
        writeBrowserExtensions(c)
        return (c.index, c.report)
    }

    /// Copies the bundled Chrome/Firefox extension and fills in this Mac's compiled rules.
    /// Loaded unpacked, it picks the new rules up when you click Reload on the browser's
    /// extensions page (a store-published build would update itself).
    private func writeBrowserExtensions(_ c: CompiledShield) {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
              FileManager.default.fileExists(atPath: bundled.path), let dnr = c.dnr, let cos = c.cosmetic else { return }
        let fm = FileManager.default
        for flavour in ["chromium", "firefox"] {
            let src = bundled.appendingPathComponent(flavour), dst = ShieldListManager.browserExtensionDir.appendingPathComponent(flavour)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? fm.copyItem(at: src, to: dst)) != nil else { continue }
            let rules = dst.appendingPathComponent("rules", isDirectory: true)
            try? fm.createDirectory(at: rules, withIntermediateDirectories: true)
            var resources: [[String: Any]] = [["id": "swoop_builtin", "enabled": true, "path": "rules/swoop_builtin.json"]]
            for rs in dnr.rulesets {
                try? DNRConverter.json(rs.rules).write(to: rules.appendingPathComponent("\(rs.id).json"))
                resources.append(["id": rs.id, "enabled": true, "path": "rules/\(rs.id).json"])
            }
            try? cos.json().write(to: dst.appendingPathComponent("cosmetic.json"))
            let manifestURL = dst.appendingPathComponent("manifest.json")
            if let d = try? Data(contentsOf: manifestURL), var m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                m["declarative_net_request"] = ["rule_resources": resources]
                if let out = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) { try? out.write(to: manifestURL) }
            }
        }
    }

    func revealBrowserExtension(_ flavour: String) {
        let u = ShieldListManager.browserExtensionDir.appendingPathComponent(flavour)
        if FileManager.default.fileExists(atPath: u.path) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else {
            Actions.info("Not ready yet", "Swoop writes the browser extension after the first list update. Click Update lists and try again.")
        }
    }
}
