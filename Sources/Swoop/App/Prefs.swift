// SPDX-License-Identifier: MIT
import AppKit
import Combine
import Foundation
import SwoopCore

/// All user settings. Simple values live in UserDefaults; lists live in JSON files in
/// ~/Library/Application Support/Swoop.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    // MARK: Hotkeys
    @Published var launcherHotkey: String { didSet { d.set(launcherHotkey, forKey: "launcherHotkey"); HotKeyCenter.shared.reload() } }
    /// Custom triggers by action id ("window.leftHalf", "command.clean-junk", …). "" = none.
    @Published var bindings: [String: String] { didSet { d.set(bindings, forKey: "bindings"); HotKeyCenter.shared.reload() } }

    // MARK: Launcher
    @Published var searchEngine: String { didSet { d.set(searchEngine, forKey: "searchEngine") } }
    @Published var fileSearchEnabled: Bool { didSet { d.set(fileSearchEnabled, forKey: "fileSearchEnabled") } }
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var clipboardRetentionDays: Int { didSet { d.set(clipboardRetentionDays, forKey: "clipboardRetentionDays") } }
    @Published var snippetExpansionEnabled: Bool { didSet { d.set(snippetExpansionEnabled, forKey: "snippetExpansionEnabled"); SnippetEngine.shared.refresh() } }
    @Published var scriptsFolder: String { didSet { d.set(scriptsFolder, forKey: "scriptsFolder"); ScriptCommands.shared.reload() } }
    @Published var snippets: [Snippet] { didSet { JSONStore.save(snippets, to: "snippets.json") } }
    @Published var quicklinks: [Quicklink] { didSet { JSONStore.save(quicklinks, to: "quicklinks.json") } }

    // MARK: Cleaner
    @Published var deletePermanently: Bool { didSet { d.set(deletePermanently, forKey: "deletePermanently") } }
    @Published var enabledJunkRules: [String] { didSet { d.set(enabledJunkRules, forKey: "enabledJunkRules") } }
    @Published var schedule: CleanupSchedule { didSet { JSONStore.save(schedule, to: "schedule.json"); CleanupScheduler.shared.reschedule() } }

    // MARK: Menu bar
    @Published var showMenuBarMonitor: Bool { didSet { d.set(showMenuBarMonitor, forKey: "showMenuBarMonitor"); MenuBarMonitor.shared.refreshVisibility() } }
    @Published var menuBarShowsStats: Bool { didSet { d.set(menuBarShowsStats, forKey: "menuBarShowsStats") } }

    // MARK: Cloud
    /// Optional: your own Google OAuth "Desktop app" client (Settings › Cloud › Advanced).
    /// Empty means Swoop's built-in client (GoogleClient.builtIn), so users just sign in.
    @Published var googleClientID: String { didSet { d.set(googleClientID, forKey: "googleClientID") } }
    @Published var googleClientSecret: String { didSet { d.set(googleClientSecret, forKey: "googleClientSecret") } }
    @Published var cloudSearchInLauncher: Bool { didSet { d.set(cloudSearchInLauncher, forKey: "cloudSearchInLauncher") } }

    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }

    private init() {
        d.register(defaults: [
            "launcherHotkey": "opt+space", "searchEngine": "google", "fileSearchEnabled": true,
            "clipboardEnabled": true, "clipboardRetentionDays": 30, "snippetExpansionEnabled": true,
            "deletePermanently": false, "showMenuBarMonitor": true, "menuBarShowsStats": true,
            "cloudSearchInLauncher": true, "onboardingDone": false,
        ])
        launcherHotkey = d.string(forKey: "launcherHotkey") ?? "opt+space"
        var b = (d.dictionary(forKey: "bindings") as? [String: String]) ?? [:]
        if d.dictionary(forKey: "bindings") == nil {
            for l in WindowLayout.allCases { if let s = l.defaultShortcut { b["window." + l.rawValue] = s } }
            b["command.clipboard-history"] = "ctrl+opt+v"
        }
        bindings = b
        searchEngine = d.string(forKey: "searchEngine") ?? "google"
        fileSearchEnabled = d.bool(forKey: "fileSearchEnabled")
        clipboardEnabled = d.bool(forKey: "clipboardEnabled")
        clipboardRetentionDays = d.integer(forKey: "clipboardRetentionDays")
        snippetExpansionEnabled = d.bool(forKey: "snippetExpansionEnabled")
        scriptsFolder = d.string(forKey: "scriptsFolder") ?? AppPaths.defaultScripts.path
        snippets = JSONStore.load([Snippet].self, from: "snippets.json") ?? Snippet.examples
        quicklinks = JSONStore.load([Quicklink].self, from: "quicklinks.json") ?? Quicklink.defaults
        deletePermanently = d.bool(forKey: "deletePermanently")
        enabledJunkRules = (d.array(forKey: "enabledJunkRules") as? [String])
            ?? JunkRules.all.filter { $0.defaultEnabled }.map { $0.id }
        schedule = JSONStore.load(CleanupSchedule.self, from: "schedule.json") ?? CleanupSchedule()
        showMenuBarMonitor = d.bool(forKey: "showMenuBarMonitor")
        menuBarShowsStats = d.bool(forKey: "menuBarShowsStats")
        googleClientID = d.string(forKey: "googleClientID") ?? ""
        googleClientSecret = d.string(forKey: "googleClientSecret") ?? ""
        cloudSearchInLauncher = d.bool(forKey: "cloudSearchInLauncher")
        onboardingDone = d.bool(forKey: "onboardingDone")
    }

    func trigger(for id: String) -> HotkeyTrigger? {
        if id == HotKeyCenter.launcherID { return HotkeyTrigger.parse(launcherHotkey) }
        guard let t = bindings[id], !t.isEmpty else { return nil }
        return HotkeyTrigger.parse(t)
    }

    func setTrigger(_ t: HotkeyTrigger?, for id: String) {
        if id == HotKeyCenter.launcherID {
            if let t = t { launcherHotkey = t.text }
            return
        }
        var b = bindings
        b[id] = t?.text ?? ""
        bindings = b
    }

    var searchURLTemplate: String {
        switch searchEngine {
        case "duckduckgo": return "https://duckduckgo.com/?q={query}"
        case "bing": return "https://www.bing.com/search?q={query}"
        case "kagi": return "https://kagi.com/search?q={query}"
        case "ecosia": return "https://www.ecosia.org/search?q={query}"
        default: return "https://www.google.com/search?q={query}"
        }
    }

    var searchEngineName: String {
        ["duckduckgo": "DuckDuckGo", "bing": "Bing", "kagi": "Kagi", "ecosia": "Ecosia"][searchEngine] ?? "Google"
    }
}
