// SPDX-License-Identifier: MIT
import AppKit
import ShieldCore
import SwoopCore

/// Menu bar item: CPU / memory / free disk at a glance, quick actions, and the way back
/// into Swoop when it runs without a Dock icon.
final class MenuBarMonitor: NSObject, NSMenuDelegate {
    static let shared = MenuBarMonitor()
    private var item: NSStatusItem?
    private var timer: Timer?
    private let reader = StatsReader()
    private(set) var stats = SystemStats()

    /// The Swoop mark as a menu-bar template image (vector PDF from Resources/MenuBar, copied into
    /// the bundle by build-app.sh). Falls back to an SF Symbol when run outside the bundle (swift run).
    private static let statusImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "SwoopMenuBarTemplate", withExtension: "pdf"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            img.accessibilityDescription = "Swoop"
            return img
        }
        let img = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Swoop")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Swoop")
        img?.isTemplate = true
        return img
    }()

    func start() {
        _ = reader.read()   // prime CPU ticks
        refreshVisibility()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// The status item always exists (it's how you reach Swoop); the stats text is optional.
    func refreshVisibility() {
        if item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            i.menu = menu
            item = i
        }
        updateTitle()
    }

    private func tick() {
        stats = reader.read()
        updateTitle()
    }

    private func updateTitle() {
        guard let b = item?.button else { return }
        b.image = Self.statusImage
        b.imagePosition = .imageLeading
        var parts: [String] = []
        var tips: [String] = []
        if Prefs.shared.showMenuBarMonitor && Prefs.shared.menuBarShowsStats {
            let mem = Double(stats.memoryUsed) / Double(max(1, stats.memoryTotal))
            parts.append(String(format: "%.0f%%  %.0f%%", stats.cpu * 100, mem * 100))
            tips.append("CPU \(Int(stats.cpu * 100))% · Memory \(Int(mem * 100))% · \(Bytes.format(stats.diskFree)) free")
        }
        // Shield: ads/trackers blocked today ("⛨ 1.2k"), or ⏸ while paused.
        if let shieldText = ShieldController.shared.menuBarText {
            parts.append("⛨ " + shieldText)
            tips.append("Swoop Shield: \(ShieldController.shared.stats?.blockedToday ?? 0) blocked today")
        }
        b.title = parts.isEmpty ? "" : " " + parts.joined(separator: "  ")
        b.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        b.toolTip = tips.isEmpty ? "Swoop" : tips.joined(separator: "\n")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        handlers.removeAll()
        let s = reader.read()
        func info(_ t: String) {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        info("CPU: \(Int(stats.cpu * 100))%")
        info("Memory: \(Bytes.format(Int64(s.memoryUsed))) of \(Bytes.format(Int64(s.memoryTotal))) used")
        info("Disk: \(Bytes.format(s.diskFree)) free of \(Bytes.format(s.diskTotal))")
        menu.addItem(.separator())
        add(menu, "Open Swoop", key: "") { LauncherController.shared.show(mode: .root) }
        add(menu, "Clipboard History", key: "") { LauncherController.shared.show(mode: .clipboard) }
        add(menu, "Smart Scan…", key: "") { CleanerWindow.show(.smartScan, autoStart: true) }
        add(menu, "Clean System Junk…", key: "") { CleanerWindow.show(.junk, autoStart: true) }
        add(menu, "Free Up RAM…", key: "") { CommandCatalog.shared.command(id: "cleaner.free-ram")?.run() }
        add(menu, "Space Lens…", key: "") { CleanerWindow.show(.spaceLens) }
        add(menu, "Restore Removed Items…", key: "") { CleanerWindow.show(.restore) }
        menu.addItem(.separator())
        let shield = ShieldController.shared
        if shield.config.enabled {
            let blocked = shield.stats?.blockedToday ?? 0
            info(shield.config.isPaused(at: Date()) ? "Shield: paused" : "Shield: \(blocked) blocked today")
            if shield.config.isPaused(at: Date()) {
                add(menu, "Resume Ad Blocking", key: "") { shield.resume() }
            } else {
                add(menu, "Pause Ads for 5 Minutes", key: "") { shield.pause(minutes: 5) }
                add(menu, "Pause Ads for 1 Hour", key: "") { shield.pause(minutes: 60) }
            }
            add(menu, "Allow Current Site", key: "") { CommandCatalog.shared.command(id: "shield.allow-site")?.run() }
        } else {
            add(menu, "Turn On Swoop Shield", key: "") { shield.setEnabled(true) }
        }
        add(menu, "Swoop Shield…", key: "") { SettingsWindow.show(tab: .shield) }
        menu.addItem(.separator())
        add(menu, "Settings…", key: ",") { SettingsWindow.show(tab: .general) }
        add(menu, "Quit Swoop", key: "q") { NSApp.terminate(nil) }
    }

    private var handlers: [Int: () -> Void] = [:]

    private func add(_ menu: NSMenu, _ title: String, key: String, _ action: @escaping () -> Void) {
        let i = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        i.target = self
        i.tag = handlers.count + 1
        handlers[i.tag] = action
        menu.addItem(i)
    }

    @objc private func run(_ sender: NSMenuItem) { handlers[sender.tag]?() }
}
