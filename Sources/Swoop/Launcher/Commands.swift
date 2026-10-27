// SPDX-License-Identifier: MIT
import AppKit
import SwoopCore

/// A built-in command: shown in launcher search, bindable to a hotkey, runnable from the
/// menu bar. Launcher sub-lists (clipboard, emoji…) open the launcher in that mode.
struct SwoopCommand: Identifiable {
    enum Group: String, CaseIterable {
        case launcher = "Swoop", window = "Window Management", system = "System", cleaner = "Cleaner",
             maintenance = "Maintenance", shield = "Shield", cloud = "Cloud", scripts = "Script Commands", quicklinks = "Quicklinks"
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let group: Group
    /// Hides the launcher before running (window/system actions act on the previous app).
    var closesLauncher = true
    let run: () -> Void
}

final class CommandCatalog {
    static let shared = CommandCatalog()
    private init() {}

    lazy var builtIn: [SwoopCommand] = makeBuiltIns()

    /// Everything a hotkey can be bound to (built-ins, script commands, quicklinks).
    var bindable: [SwoopCommand] { builtIn + ScriptCommands.shared.commands + quicklinkCommands }

    func command(id: String) -> SwoopCommand? { bindable.first { $0.id == id } }

    var quicklinkCommands: [SwoopCommand] {
        Prefs.shared.quicklinks.map { q in
            SwoopCommand(id: "quicklink." + q.id.uuidString, title: q.name, subtitle: q.template, symbol: "link",
                         keywords: [q.keyword], group: .quicklinks, closesLauncher: !q.needsQuery) {
                if q.needsQuery {
                    LauncherController.shared.show(mode: .argument(title: q.name, placeholder: "Query") { text in
                        Actions.openURLString(q.resolve(query: text))
                    })
                } else {
                    Actions.openURLString(q.resolve(query: ""))
                }
            }
        }
    }

    private func makeBuiltIns() -> [SwoopCommand] {
        var c: [SwoopCommand] = []
        func add(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ kw: [String], _ g: SwoopCommand.Group,
                 closes: Bool = true, _ run: @escaping () -> Void) {
            c.append(SwoopCommand(id: id, title: title, subtitle: subtitle, symbol: symbol, keywords: kw, group: g,
                                  closesLauncher: closes, run: run))
        }
        let L = LauncherController.shared
        // Launcher
        add("command.clipboard-history", "Clipboard History", "Search, pin and paste what you copied", "doc.on.clipboard",
            ["paste", "copy", "history"], .launcher, closes: false) { L.show(mode: .clipboard) }
        add("command.search-snippets", "Search Snippets", "Insert a saved snippet", "text.quote", ["snippet", "text", "expand"],
            .launcher, closes: false) { L.show(mode: .snippets) }
        add("command.emoji", "Search Emoji & Symbols", "Find and paste an emoji", "face.smiling", ["emoji", "symbol", "smiley"],
            .launcher, closes: false) { L.show(mode: .emoji) }
        add("command.search-files", "Search Files", "Find files with Spotlight", "doc.text.magnifyingglass", ["find", "file", "spotlight"],
            .launcher, closes: false) { L.show(mode: .files) }
        add("command.quicklinks", "Search Quicklinks", "Your saved links and searches", "link", ["quicklink", "url", "bookmark"],
            .launcher, closes: false) { L.show(mode: .quicklinks) }
        add("command.calculator", "Calculator", "Type a sum or a conversion, e.g. 12% of 80 or 5 km to mi", "plus.forwardslash.minus",
            ["math", "calc", "convert", "units"], .launcher, closes: false) { L.show(mode: .root, query: "") }
        add("command.manage-snippets", "Manage Snippets", "Create and edit snippets", "square.and.pencil", ["snippet", "new"],
            .launcher) { SettingsWindow.show(tab: .snippets) }
        add("command.settings", "Swoop Settings", "Hotkeys, modules and permissions", "gearshape", ["preferences", "config"],
            .launcher) { SettingsWindow.show(tab: .general) }
        add("command.hotkeys", "Configure Hotkeys", "Change any shortcut", "keyboard", ["shortcut", "keys", "bind"],
            .launcher) { SettingsWindow.show(tab: .hotkeys) }
        add("command.open-scripts", "Open Script Commands Folder", "Raycast-compatible scripts live here", "folder",
            ["scripts", "extensions"], .scripts) { NSWorkspace.shared.open(URL(fileURLWithPath: Prefs.shared.scriptsFolder)) }
        add("command.reload-scripts", "Reload Script Commands", "Re-read the scripts folder", "arrow.clockwise",
            ["scripts", "refresh"], .scripts) { ScriptCommands.shared.reload() }
        add("command.quit-swoop", "Quit Swoop", "", "power", ["exit"], .launcher) { NSApp.terminate(nil) }

        // Window management
        for l in WindowLayout.allCases {
            add("window." + l.rawValue, l.title, "Window Management", Self.windowSymbol(l), ["window", "resize", "snap"], .window) {
                WindowManager.shared.apply(l)
            }
        }

        // System
        add("system.lock", "Lock Screen", "", "lock", ["lock"], .system) { SystemActions.lockScreen() }
        add("system.sleep", "Sleep", "", "moon.zzz", ["sleep"], .system) { SystemActions.sleep() }
        add("system.sleep-displays", "Sleep Displays", "", "display", ["screen", "off"], .system) { SystemActions.sleepDisplays() }
        add("system.empty-trash", "Empty Trash", "Permanently erase the items in the Trash", "trash", ["bin"], .system) {
            SystemActions.emptyTrash()
        }
        add("system.dark-mode", "Toggle Dark Mode", "", "circle.lefthalf.filled", ["appearance", "light", "theme"], .system) {
            SystemActions.toggleDarkMode()
        }
        add("system.restart", "Restart", "", "arrow.counterclockwise", ["reboot"], .system) { SystemActions.restart() }
        add("system.shutdown", "Shut Down", "", "power", ["turn off", "power off"], .system) { SystemActions.shutDown() }
        add("system.logout", "Log Out", "", "rectangle.portrait.and.arrow.right", ["sign out"], .system) { SystemActions.logOut() }
        add("system.eject-all", "Eject All Disks", "Unmount external and disk-image volumes", "eject", ["unmount", "usb"], .system) {
            SystemActions.ejectAll()
        }
        add("system.hidden-files", "Toggle Hidden Files in Finder", "", "eye", ["dotfiles", "show"], .system) {
            SystemActions.toggleHiddenFiles()
        }
        add("system.quit-all", "Quit All Apps", "Asks each app to quit (unsaved work prompts)", "xmark.square", ["close"], .system) {
            SystemActions.quitAllApps()
        }

        // Cleaner
        let C = CleanerWindow.self
        add("cleaner.smart-scan", "Smart Scan", "Junk, leftovers, security and updates in one review", "sparkles",
            ["clean", "scan", "optimize"], .cleaner) { C.show(.smartScan, autoStart: true) }
        add("cleaner.clean-junk", "Clean System Junk", "Caches, logs, Xcode junk, broken downloads", "trash.circle",
            ["junk", "cache", "clean", "free space"], .cleaner) { C.show(.junk, autoStart: true) }
        add("cleaner.space-lens", "Space Lens", "See what takes up your disk", "chart.pie", ["disk", "usage", "storage", "map"],
            .cleaner) { C.show(.spaceLens) }
        add("cleaner.large-files", "Large & Old Files", "Find big files you've forgotten", "doc.zipper", ["big", "old", "large files"],
            .cleaner) { C.show(.largeFiles, autoStart: true) }
        add("cleaner.uninstall", "Uninstall an App", "Remove an app and everything it left behind", "xmark.bin",
            ["uninstaller", "remove app", "delete app"], .cleaner) { C.show(.uninstaller) }
        add("cleaner.duplicates", "Find Duplicates", "Identical files in Downloads, Documents, Desktop", "doc.on.doc",
            ["duplicate", "copies"], .cleaner) { C.show(.duplicates) }
        add("cleaner.login-items", "Login Items & Launch Agents", "What starts with your Mac", "power.circle",
            ["startup", "launch agents", "background"], .cleaner) { C.show(.loginItems) }
        add("cleaner.security", "Security Check", "Look for adware and suspicious background items", "shield.lefthalf.filled",
            ["malware", "adware", "virus"], .cleaner) { C.show(.security, autoStart: true) }
        add("cleaner.updates", "Check App Updates", "Sparkle, Homebrew and App Store", "arrow.down.app", ["update", "upgrade", "outdated"],
            .cleaner) { C.show(.updates, autoStart: true) }
        add("cleaner.maintenance", "Maintenance", "Flush DNS, reindex Spotlight, and more", "wrench.and.screwdriver",
            ["fix", "repair"], .cleaner) { C.show(.maintenance) }
        add("cleaner.privacy", "Privacy", "Recent items and browser history", "hand.raised", ["history", "recent"],
            .cleaner) { C.show(.privacy) }
        add("cleaner.cloud", "Cloud Storage", "Google Drive and iCloud Drive usage", "icloud", ["drive", "storage", "cloud"],
            .cleaner) { C.show(.cloud) }
        add("cleaner.restore", "Restore Removed Items", "Undo anything Swoop removed", "arrow.uturn.backward.circle",
            ["undo", "restore", "history"], .cleaner) { C.show(.restore) }
        add("cleaner.battery", "Battery Health", "Capacity, cycles and condition", "battery.75", ["battery", "power"],
            .cleaner) { C.show(.battery) }
        add("cleaner.free-ram", "Free Up RAM", "Purge inactive memory (asks for your password)", "memorychip", ["memory", "ram", "purge"],
            .cleaner) { Maintenance.run(MaintenanceTask.all.first { $0.id == "free-purgeable" }!) }
        for t in MaintenanceTask.all where t.id != "free-purgeable" {
            add("maintenance." + t.id, t.title, t.needsAdmin ? "Maintenance · asks for your password" : "Maintenance",
                "wrench", ["maintenance", "fix"], .maintenance) { Maintenance.run(t) }
        }

        // Cloud
        add("cloud.search-drive", "Search Google Drive", "Find files in your Drive", "magnifyingglass.circle",
            ["google", "drive", "gdrive"], .cloud, closes: false) { L.show(mode: .cloud(.googleDrive)) }
        add("cloud.upload-drive", "Upload File to Google Drive", "Pick a file to upload", "icloud.and.arrow.up",
            ["upload", "google drive"], .cloud) { CloudManager.shared.quickUpload() }
        add("cloud.search-icloud", "Search iCloud Drive", "Files in your iCloud Drive folder", "icloud",
            ["icloud", "drive"], .cloud, closes: false) { L.show(mode: .cloud(.iCloudDrive)) }
        add("cloud.open-icloud", "Open iCloud Drive", "", "folder", ["icloud"], .cloud) { CloudManager.shared.openICloudFolder() }

        // Shield (system-wide ad blocking)
        c += ShieldCommands.make()
        return c
    }

    static func windowSymbol(_ l: WindowLayout) -> String {
        switch l {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .maximize, .almostMaximize: return "rectangle.fill"
        case .center: return "rectangle.center.inset.filled"
        case .restore: return "arrow.uturn.backward"
        case .nextDisplay: return "rectangle.righthalf.inset.filled.arrow.right"
        case .previousDisplay: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter: return "square.grid.2x2"
        default: return "rectangle.split.3x1"
        }
    }
}
