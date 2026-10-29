// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import SwoopCore

enum ItemIcon {
    case symbol(String)
    case file(String)        // icon of a file/app at this path
    case emoji(String)
    case image(NSImage)
}

struct LauncherAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var shortcut: String? = nil
    var closes = true
    let run: () -> Void
}

struct LauncherItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String = ""
    var icon: ItemIcon = .symbol("questionmark")
    var accessory: String? = nil
    var section: String = "Results"
    var keywords: [String] = []
    var score: Double = 0
    var actions: [LauncherAction]
    /// Extra content shown in the detail pane (clipboard preview, script output…).
    var preview: String? = nil
    var previewImage: String? = nil
}

final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published private(set) var items: [LauncherItem] = []
    @Published var selection = 0
    @Published private(set) var mode: LauncherMode = .root
    @Published var showActions = false
    @Published var actionSelection = 0
    @Published var toast: String?
    @Published var focusToken = 0
    /// >0 while a sheet/alert of ours is up, so losing key focus doesn't close Swoop.
    var keepOpenDepth = 0

    private var ranker = JSONStore.load(UsageRanker.self, from: "ranking.json") ?? UsageRanker()
    private var asyncResults: [String: [LauncherItem]] = [:]   // "files", "cloud"
    private var generation = 0

    var selectedItem: LauncherItem? { items.indices.contains(selection) ? items[selection] : nil }

    func enter(_ m: LauncherMode, query q: String) {
        mode = m
        showActions = false
        asyncResults = [:]
        if case .root = m { Providers.shared.refreshApps(); Providers.shared.invalidate() }
        if query == q { refresh() } else { query = q }
        selection = 0
    }

    // MARK: results

    func refresh() {
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [LauncherItem]
        switch mode {
        case .root:
            out = rootItems(q)
            if q.count >= 2 { startAsyncSearches(q, gen: gen) }
        case .clipboard: out = ClipboardManager.shared.items(matching: q)
        case .snippets: out = Providers.shared.snippetItems(q)
        case .emoji: out = Providers.shared.emojiItems(q)
        case .quicklinks: out = Providers.shared.quicklinkItems(q)
        case .files:
            out = asyncResults["files"] ?? []
            if q.count >= 2 { startFileSearch(q, gen: gen) }
        case .cloud(let s):
            out = asyncResults["cloud"] ?? []
            if q.count >= 2 { startCloudSearch(q, service: s, gen: gen) }
            if out.isEmpty { out = Providers.shared.cloudHint(s, query: q) }
        case .argument(let title, _, let handler):
            out = [LauncherItem(id: "arg", title: q.isEmpty ? title : q, subtitle: "Press Return to run", icon: .symbol("return"),
                                actions: [LauncherAction(title: "Run", symbol: "return") { handler(q) }])]
        case .output(let title, let text):
            out = [LauncherItem(id: "output", title: title, subtitle: "Output", icon: .symbol("terminal"),
                                actions: [LauncherAction(title: "Copy Output", symbol: "doc.on.doc") { Actions.copy(text) }],
                                preview: text)]
        }
        items = out
        if selection >= items.count { selection = max(0, items.count - 1) }
    }

    private func rootItems(_ q: String) -> [LauncherItem] {
        var out: [LauncherItem] = []
        if q.isEmpty {
            let index = Providers.shared.staticIndex()
            let byID = Dictionary(index.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let favs = ranker.favourites.compactMap { byID[$0] }.map { item -> LauncherItem in
                var i = item; i.section = "Favourites"; return i
            }
            let recent = ranker.top(6).filter { !ranker.isFavourite($0) }.compactMap { byID[$0] }.map { item -> LauncherItem in
                var i = item; i.section = "Recently used"; return i
            }
            // Always follow with the full list (apps, commands, settings), so the
            // root never shrinks to just what was used last time.
            var seen = Set((favs + recent).map { $0.id })
            func rest(_ section: String, _ items: [LauncherItem]) -> [LauncherItem] {
                items.filter { seen.insert($0.id).inserted }.map { var i = $0; i.section = section; return i }
            }
            let byTitle: (LauncherItem, LauncherItem) -> Bool = {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            let apps = index.filter { $0.id.hasPrefix("app.") }.sorted(by: byTitle)
            let settings = index.filter { $0.id.hasPrefix("settings.") }.sorted(by: byTitle)
            let appOrSettingIDs = Set((apps + settings).map { $0.id })
            let commands = index.filter { !appOrSettingIDs.contains($0.id) }
            out = favs + recent
            if out.isEmpty { out = Providers.shared.starterItems(); seen.formUnion(out.map { $0.id }) }
            out += rest("Applications", apps) + rest("Commands", commands) + rest("System Settings", settings)
            return out
        }
        if let calc = Providers.shared.calculatorItem(q) { out.append(calc) }
        out += Providers.shared.uninstallShortcut(q)
        var scored: [LauncherItem] = []
        for var item in Providers.shared.staticIndex() {
            guard let s = FuzzyMatcher.bestScore(q, fields: [item.title] + item.keywords) else { continue }
            item.score = s + ranker.bonus(for: item.id)
            scored.append(item)
        }
        scored.sort { $0.score > $1.score }
        out += scored.prefix(30)
        out += Providers.shared.quicklinkQueryItems(q)
        out += asyncResults["files"] ?? []
        out += asyncResults["cloud"] ?? []
        out += Providers.shared.webSearchFallback(q)
        return out
    }

    private func startAsyncSearches(_ q: String, gen: Int) {
        if Prefs.shared.fileSearchEnabled && q.count >= 3 { startFileSearch(q, gen: gen) }
        if Prefs.shared.cloudSearchInLauncher && q.count >= 3 && CloudManager.shared.drive.isSignedIn {
            startCloudSearch(q, service: .googleDrive, gen: gen)
        }
    }

    private func startFileSearch(_ q: String, gen: Int) {
        FileSearch.shared.search(q) { [weak self] items in
            guard let self = self, gen == self.generation || self.query.trimmingCharacters(in: .whitespaces) == q else { return }
            self.asyncResults["files"] = items
            self.mergeAsync()
        }
    }

    private func startCloudSearch(_ q: String, service: CloudService, gen: Int) {
        CloudManager.shared.search(q, service: service) { [weak self] files in
            guard let self = self, self.query.trimmingCharacters(in: .whitespaces) == q else { return }
            self.asyncResults["cloud"] = files.map { Providers.shared.cloudItem($0) }
            self.mergeAsync()
        }
    }

    /// Re-compose without restarting the async searches.
    private func mergeAsync() {
        let keepID = selectedItem?.id
        let q = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .root: items = rootItems(q)
        case .files: items = asyncResults["files"] ?? []
        case .cloud(let s):
            items = asyncResults["cloud"] ?? []
            if items.isEmpty { items = Providers.shared.cloudHint(s, query: q) }
        default: return
        }
        if let k = keepID, let i = items.firstIndex(where: { $0.id == k }) { selection = i }
        if selection >= items.count { selection = max(0, items.count - 1) }
    }

    // MARK: navigation & running

    func move(_ delta: Int) {
        if showActions {
            let n = selectedItem?.actions.count ?? 0
            guard n > 0 else { return }
            actionSelection = (actionSelection + delta + n) % n
            return
        }
        guard !items.isEmpty else { return }
        selection = min(max(0, selection + delta), items.count - 1)
    }

    func runPrimary(secondary: Bool) {
        guard let item = selectedItem else { return }
        let idx = secondary ? 1 : 0
        guard item.actions.indices.contains(idx) else { return }
        run(item.actions[idx], item: item)
    }

    func runSelectedAction() {
        guard let item = selectedItem, item.actions.indices.contains(actionSelection) else { return }
        showActions = false
        run(item.actions[actionSelection], item: item)
    }

    func runIndex(_ i: Int) {
        guard items.indices.contains(i) else { return }
        selection = i
        runPrimary(secondary: false)
    }

    func run(_ action: LauncherAction, item: LauncherItem) {
        ranker.recordUse(item.id)
        JSONStore.save(ranker, to: "ranking.json")
        if action.closes {
            LauncherController.shared.hide()
            // Let the previous app become active first (window layouts, paste).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { action.run() }
        } else {
            action.run()
        }
    }

    func toggleFavouriteSelected() {
        guard let item = selectedItem, mode.isRoot else { return }
        ranker.toggleFavourite(item.id)
        JSONStore.save(ranker, to: "ranking.json")
        flash(ranker.isFavourite(item.id) ? "Added to Favourites" : "Removed from Favourites")
        refresh()
    }

    func isFavourite(_ id: String) -> Bool { ranker.isFavourite(id) }

    func togglePinSelected() {
        guard let item = selectedItem, let uuid = UUID(uuidString: item.id) else { return }
        ClipboardManager.shared.togglePin(uuid)
        refresh()
    }

    /// ⌘C copies the selected result's text where that makes sense (calculator, clipboard, emoji).
    func copySelected() -> Bool {
        guard let item = selectedItem, let copy = item.actions.first(where: { $0.title.hasPrefix("Copy") }) else { return false }
        copy.run()
        flash("Copied")
        return true
    }

    func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }
}
