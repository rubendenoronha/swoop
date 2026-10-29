// SPDX-License-Identifier: MIT
import AppKit
import SwoopCore

struct InstalledApp {
    let name: String
    let path: String
    let bundleID: String?
}

/// Builds launcher items from apps, System Settings panes, commands, quicklinks,
/// scripts, snippets, emoji, the calculator and the web-search fallback.
final class Providers {
    static let shared = Providers()
    private var apps: [InstalledApp] = []
    private var lastAppScan = Date.distantPast
    private var cachedIndex: [LauncherItem]?

    static let appFolders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                             "/System/Applications/Utilities", "/System/Library/CoreServices/Applications",
                             NSHomeDirectory() + "/Applications"]

    func refreshApps(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastAppScan) > 30 else { return }
        lastAppScan = Date()
        apps = Self.scanApps()
        cachedIndex = nil
    }

    static func scanApps() -> [InstalledApp] {
        var out: [InstalledApp] = []
        var seen = Set<String>()
        let fm = FileManager.default
        func visit(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names {
                let p = (dir as NSString).appendingPathComponent(n)
                if n.hasSuffix(".app") {
                    let name = String(n.dropLast(4))
                    guard !seen.contains(p) else { continue }
                    seen.insert(p)
                    out.append(InstalledApp(name: name, path: p, bundleID: Bundle(path: p)?.bundleIdentifier))
                } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue, !n.hasPrefix(".") {
                        visit(p, depth: depth - 1)
                    }
                }
            }
        }
        for f in appFolders { visit(f, depth: 1) }
        out.append(InstalledApp(name: "Finder", path: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder"))
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var installedApps: [InstalledApp] {
        if apps.isEmpty { refreshApps(force: true) }
        return apps
    }

    /// Apps + System Settings + commands + scripts (everything that doesn't need a query).
    func staticIndex() -> [LauncherItem] {
        if let c = cachedIndex { return c }
        var out: [LauncherItem] = []
        for a in installedApps { out.append(appItem(a)) }
        for p in SettingsPanes.all {
            out.append(LauncherItem(id: "settings." + p.title, title: p.title, subtitle: "System Settings",
                                    icon: .file("/System/Applications/System Settings.app"), accessory: "Settings",
                                    section: "Results", keywords: p.keywords,
                                    actions: [LauncherAction(title: "Open", symbol: "arrow.up.forward.app") {
                                        Actions.openURLString(p.urlString)
                                    }]))
        }
        for c in CommandCatalog.shared.bindable {
            out.append(commandItem(c))
        }
        cachedIndex = out
        return out
    }

    func invalidate() { cachedIndex = nil }

    func commandItem(_ c: SwoopCommand) -> LauncherItem {
        let hotkey = Prefs.shared.trigger(for: c.id)?.display
        let icon: ItemIcon
        if c.group == .scripts, let s = ScriptCommands.shared.script(forCommandID: c.id), let e = s.icon, e.count <= 2 {
            icon = .emoji(e)
        } else {
            icon = .symbol(c.symbol)
        }
        // A command whose permission is missing stays in the list, says so, and explains
        // itself inline instead of closing the launcher and doing nothing.
        let blocked = PermissionFeature.forCommand(id: c.id).flatMap { f in Permissions.isAvailable(f) ? nil : f }
        let run: LauncherAction
        if let f = blocked {
            run = LauncherAction(title: "Set Up…", symbol: "lock.shield", closes: false) { PermissionGate.present(f) }
        } else {
            run = LauncherAction(title: "Run", symbol: "return", closes: c.closesLauncher, run: c.run)
        }
        return LauncherItem(id: c.id, title: c.title, subtitle: c.subtitle.isEmpty ? c.group.rawValue : c.subtitle,
                            icon: icon, accessory: blocked != nil ? "Needs setup" : (hotkey ?? c.group.rawValue), keywords: c.keywords,
                            actions: [
                                run,
                                LauncherAction(title: "Set Hotkey…", symbol: "keyboard", shortcut: "⌘↩") {
                                    SettingsWindow.show(tab: .hotkeys)
                                },
                            ])
    }

    func appItem(_ a: InstalledApp) -> LauncherItem {
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == a.path }
        var actions = [
            LauncherAction(title: "Open", symbol: "arrow.up.forward.app") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: a.path), configuration: NSWorkspace.OpenConfiguration())
            },
            LauncherAction(title: "Show in Finder", symbol: "folder", shortcut: "⌘↩") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)])
            },
        ]
        let isPax = PaxGuardrails.isPaxApp(path: a.path, bundleID: a.bundleID)
        if running != nil && !isPax {
            actions.append(LauncherAction(title: "Quit", symbol: "xmark.circle") {
                NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == a.path }?.terminate()
            })
            actions.append(LauncherAction(title: "Force Quit", symbol: "exclamationmark.octagon") {
                NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == a.path }?.forceTerminate()
            })
        }
        if !isPax {
            actions.append(LauncherAction(title: "Uninstall…", symbol: "trash") {
                CleanerWindow.show(.uninstaller, appPath: a.path)
            })
        }
        actions.append(LauncherAction(title: "Copy Path", symbol: "doc.on.doc", closes: false) { Actions.copy(a.path) })
        return LauncherItem(id: "app." + (a.bundleID ?? a.path), title: a.name, subtitle: a.path,
                            icon: .file(a.path), accessory: running != nil ? "Running" : "Application",
                            keywords: [a.bundleID?.components(separatedBy: ".").last ?? ""], actions: actions)
    }

    func starterItems() -> [LauncherItem] {
        let ids = ["command.clipboard-history", "cleaner.smart-scan", "window.leftHalf", "command.emoji",
                   "cleaner.space-lens", "command.search-snippets", "command.settings"]
        let index = staticIndex()
        return ids.compactMap { id in index.first { $0.id == id } }.map { var i = $0; i.section = "Get started"; return i }
    }

    // MARK: query-dependent

    func calculatorItem(_ q: String) -> LauncherItem? {
        guard let r = Calculator.evaluate(q) else { return nil }
        let text = r.display
        var subtitle = q
        if case .conversion(_, _, let from, let fromUnit) = r { subtitle = "\(Calculator.format(from)) \(fromUnit)" }
        return LauncherItem(id: "calc", title: text, subtitle: subtitle + "  =", icon: .symbol("plus.forwardslash.minus"),
                            accessory: "Calculator", section: "Calculator",
                            actions: [
                                LauncherAction(title: "Copy Answer", symbol: "doc.on.doc") { Actions.copy(Self.plainNumber(r)) },
                                LauncherAction(title: "Paste Answer", symbol: "doc.on.clipboard", shortcut: "⌘↩") {
                                    Actions.paste(Self.plainNumber(r))
                                },
                                LauncherAction(title: "Copy with Unit", symbol: "textformat") { Actions.copy(text) },
                            ])
    }

    static func plainNumber(_ r: CalcResult) -> String { Calculator.format(r.value) }

    func uninstallShortcut(_ q: String) -> [LauncherItem] {
        let lower = q.lowercased()
        guard lower.hasPrefix("uninstall ") else { return [] }
        let name = String(q.dropFirst("uninstall ".count))
        return installedApps.filter { !($0.bundleID ?? "").hasPrefix("com.apple.") && !$0.path.hasPrefix("/System")
                && !PaxGuardrails.isPaxApp(path: $0.path, bundleID: $0.bundleID) }
            .compactMap { a -> (InstalledApp, Double)? in
                FuzzyMatcher.match(name, in: a.name).map { (a, $0.score) }
            }
            .sorted { $0.1 > $1.1 }.prefix(5).map { a, _ in
                LauncherItem(id: "uninstall." + a.path, title: "Uninstall \(a.name)", subtitle: "App + leftovers, reviewed before removal",
                             icon: .file(a.path), accessory: "Cleaner", section: "Cleaner",
                             actions: [LauncherAction(title: "Review & Uninstall", symbol: "trash") {
                                 CleanerWindow.show(.uninstaller, appPath: a.path)
                             }])
            }
    }

    func quicklinkQueryItems(_ q: String) -> [LauncherItem] {
        // "gh swoop" → run the quicklink with keyword gh and query "swoop"
        let parts = q.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        return Prefs.shared.quicklinks.filter { !$0.keyword.isEmpty && $0.keyword.lowercased() == parts[0].lowercased() && $0.needsQuery }
            .map { link in
                LauncherItem(id: "quicklink." + link.id.uuidString, title: "\(link.name): \(parts[1])",
                             subtitle: link.resolve(query: parts[1]), icon: .symbol("link"), accessory: "Quicklink",
                             section: "Quicklinks",
                             actions: [LauncherAction(title: "Open", symbol: "safari") { Actions.openURLString(link.resolve(query: parts[1])) },
                                       LauncherAction(title: "Copy Link", symbol: "doc.on.doc", closes: false) {
                                           Actions.copy(link.resolve(query: parts[1]))
                                       }])
            }
    }

    func quicklinkItems(_ q: String) -> [LauncherItem] {
        Prefs.shared.quicklinks.compactMap { link -> LauncherItem? in
            if !q.isEmpty && FuzzyMatcher.bestScore(q, fields: [link.name, link.keyword]) == nil { return nil }
            return LauncherItem(id: "quicklink." + link.id.uuidString, title: link.name, subtitle: link.template,
                                icon: .symbol("link"), accessory: link.keyword.isEmpty ? nil : link.keyword,
                                actions: [LauncherAction(title: "Open", symbol: "safari", closes: !link.needsQuery) {
                                    if link.needsQuery {
                                        LauncherController.shared.show(mode: .argument(title: link.name, placeholder: "Search \(link.name)…") {
                                            Actions.openURLString(link.resolve(query: $0))
                                        })
                                    } else {
                                        Actions.openURLString(link.resolve(query: ""))
                                    }
                                },
                                LauncherAction(title: "Edit Quicklinks…", symbol: "pencil") { SettingsWindow.show(tab: .quicklinks) }])
        }
    }

    func webSearchFallback(_ q: String) -> [LauncherItem] {
        let prefs = Prefs.shared
        let link = Quicklink(name: "Web", template: prefs.searchURLTemplate)
        return [LauncherItem(id: "web.search", title: "Search \(prefs.searchEngineName) for \"\(q)\"", subtitle: "Web search",
                             icon: .symbol("globe"), accessory: "↩", section: "Fallback",
                             actions: [LauncherAction(title: "Search", symbol: "magnifyingglass") {
                                 Actions.openURLString(link.resolve(query: q))
                             }])]
    }

    func snippetItems(_ q: String) -> [LauncherItem] {
        Prefs.shared.snippets.compactMap { s -> LauncherItem? in
            if !q.isEmpty && FuzzyMatcher.bestScore(q, fields: [s.name, s.keyword, s.text]) == nil { return nil }
            let expanded = SnippetExpander.expand(s.text, clipboard: NSPasteboard.general.string(forType: .string)).text
            return LauncherItem(id: "snippet." + s.id.uuidString, title: s.name, subtitle: s.keyword, icon: .symbol("text.quote"),
                                accessory: s.keyword,
                                actions: [LauncherAction(title: "Paste Snippet", symbol: "doc.on.clipboard") { Actions.paste(expanded) },
                                          LauncherAction(title: "Copy Snippet", symbol: "doc.on.doc", closes: false) { Actions.copy(expanded) },
                                          LauncherAction(title: "Edit Snippets…", symbol: "pencil") { SettingsWindow.show(tab: .snippets) }],
                                preview: expanded)
        }
    }

    func emojiItems(_ q: String) -> [LauncherItem] {
        EmojiCatalog.search(q, limit: 120).map { e in
            LauncherItem(id: "emoji." + e.emoji, title: e.name.capitalized, icon: .emoji(e.emoji),
                         actions: [LauncherAction(title: "Paste Emoji", symbol: "doc.on.clipboard") { Actions.paste(e.emoji) },
                                   LauncherAction(title: "Copy Emoji", symbol: "doc.on.doc", closes: false) { Actions.copy(e.emoji) }])
        }
    }

    func cloudItem(_ f: CloudFile) -> LauncherItem {
        var actions: [LauncherAction] = []
        if let local = f.localPath {
            actions.append(LauncherAction(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(URL(fileURLWithPath: local)) })
            actions.append(LauncherAction(title: "Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: local)])
            })
        }
        if let web = f.webURL {
            actions.append(LauncherAction(title: "Open in Browser", symbol: "safari") { Actions.openURLString(web) })
            actions.append(LauncherAction(title: "Copy Link", symbol: "link", closes: false) { Actions.copy(web) })
        }
        let size = f.size.map { Bytes.format($0) } ?? ""
        let icon: ItemIcon = f.localPath.map { .file($0) } ?? .symbol(f.mimeType?.contains("folder") == true ? "folder" : "doc")
        return LauncherItem(id: "cloud.\(f.service.rawValue).\(f.id)", title: f.name,
                            subtitle: [f.service.title, size].filter { !$0.isEmpty }.joined(separator: " · "),
                            icon: icon, accessory: f.service.title, section: f.service.title, actions: actions)
    }

    func cloudHint(_ s: CloudService, query: String) -> [LauncherItem] {
        if s == .googleDrive && !CloudManager.shared.drive.isSignedIn {
            return [LauncherItem(id: "cloud.signin", title: "Sign in to Google Drive", subtitle: "Opens your browser (OAuth with PKCE)",
                                 icon: .symbol("person.crop.circle.badge.plus"),
                                 actions: [LauncherAction(title: "Sign In", symbol: "person") { CloudManager.shared.drive.signIn() }])]
        }
        if query.count < 2 {
            return [LauncherItem(id: "cloud.type", title: "Type to search \(s.title)", icon: .symbol("magnifyingglass"), actions: [])]
        }
        return [LauncherItem(id: "cloud.none", title: "No matches yet…", subtitle: s.title, icon: .symbol("hourglass"), actions: [])]
    }
}

/// Spotlight file search (NSMetadataQuery, home folder scope).
final class FileSearch: NSObject {
    static let shared = FileSearch()
    private var query: NSMetadataQuery?
    private var completion: (([LauncherItem]) -> Void)?
    private var debounce: DispatchWorkItem?

    func search(_ text: String, completion: @escaping ([LauncherItem]) -> Void) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start(text, completion: completion) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func start(_ text: String, completion: @escaping ([LauncherItem]) -> Void) {
        query?.stop()
        NotificationCenter.default.removeObserver(self)
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(text)*")
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        self.completion = completion
        NotificationCenter.default.addObserver(self, selector: #selector(done(_:)), name: .NSMetadataQueryDidFinishGathering, object: q)
        query = q
        q.start()
    }

    @objc private func done(_ n: Notification) {
        guard let q = n.object as? NSMetadataQuery else { return }
        q.disableUpdates()
        var items: [LauncherItem] = []
        for i in 0..<min(q.resultCount, 20) {
            guard let r = q.result(at: i) as? NSMetadataItem, let path = r.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.contains("/Library/") || path.contains("/.") { continue }
            let url = URL(fileURLWithPath: path)
            items.append(LauncherItem(id: "file." + path, title: url.lastPathComponent,
                                      subtitle: (path as NSString).abbreviatingWithTildeInPath,
                                      icon: .file(path), accessory: "File", section: "Files",
                                      actions: [
                                          LauncherAction(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) },
                                          LauncherAction(title: "Show in Finder", symbol: "folder", shortcut: "⌘↩") {
                                              NSWorkspace.shared.activateFileViewerSelecting([url])
                                          },
                                          LauncherAction(title: "Quick Look", symbol: "eye") { Actions.quickLook(url) },
                                          LauncherAction(title: "Copy Path", symbol: "doc.on.doc", closes: false) { Actions.copy(path) },
                                          LauncherAction(title: "Upload to Google Drive", symbol: "icloud.and.arrow.up") {
                                              CloudManager.shared.upload(url)
                                          },
                                          LauncherAction(title: "Move to Trash", symbol: "trash") {
                                              FileRemover.shared.removeWithConfirmation([url], module: "Launcher", reason: "You chose to move this file to the Trash.")
                                          },
                                      ]))
        }
        q.stop()
        completion?(items)
    }
}
