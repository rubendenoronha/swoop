// SPDX-License-Identifier: MIT
import AppKit
import ShieldCore

/// Launcher commands for Shield. They live in the "Shield" group, so every one of them can
/// get its own hotkey in Settings › Hotkeys like any other Swoop command.
enum ShieldCommands {
    static func make() -> [SwoopCommand] {
        let S = ShieldController.shared
        let L = LauncherController.shared
        var c: [SwoopCommand] = []
        func add(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ kw: [String], closes: Bool = true, _ run: @escaping () -> Void) {
            c.append(SwoopCommand(id: "shield." + id, title: title, subtitle: subtitle, symbol: symbol, keywords: kw + ["shield", "ads", "adblock"],
                                  group: .shield, closesLauncher: closes, run: run))
        }
        add("toggle", "Toggle Swoop Shield", "Turn system-wide ad blocking on or off", "shield.lefthalf.filled", ["block", "on", "off"]) {
            S.setEnabled(!S.config.enabled)
            Notifier.show(S.config.enabled ? "Swoop Shield is on" : "Swoop Shield is off")
        }
        add("pause-5", "Pause Ads for 5 Minutes", "Let everything through, then block again", "pause.circle", ["pause", "disable"]) { S.pause(minutes: 5) }
        add("pause-60", "Pause Ads for 1 Hour", "", "pause.circle", ["pause", "disable"]) { S.pause(minutes: 60) }
        add("resume", "Resume Ad Blocking", "End a pause now", "play.circle", ["resume", "unpause", "enable"]) { S.resume() }
        add("allow-site", "Allow This Site", "Stop blocking the site open in your browser", "checkmark.shield", ["whitelist", "allowlist", "unblock", "site"]) {
            if let url = BrowserURL.frontmost() {
                S.allow(site: url)
            } else {
                L.show(mode: .argument(title: "Allow a Site", placeholder: "example.com") { S.allow(site: $0) })
            }
        }
        add("pause-site", "Pause Ads on This Site for 1 Hour", "Temporarily stop blocking on the site in your browser", "pause.rectangle", ["site", "pause"]) {
            if let url = BrowserURL.frontmost() {
                S.pause(site: url, minutes: 60)
                Notifier.show("Paused on \(DomainName.registrableDomain(DomainName.host(fromURLOrHost: url) ?? url)) for 1 hour")
            } else {
                L.show(mode: .argument(title: "Pause a Site", placeholder: "example.com") { S.pause(site: $0, minutes: 60) })
            }
        }
        add("block-site", "Block a Domain", "Add a domain to your Shield rules", "xmark.shield", ["block", "domain", "blacklist"], closes: false) {
            L.show(mode: .argument(title: "Block a Domain", placeholder: "ads.example.com") { S.block(site: $0) })
        }
        add("stats", "Shield Stats", "What Shield blocked today", "chart.bar", ["statistics", "blocked", "count"], closes: false) {
            L.show(mode: .output(title: "Shield Stats", text: S.statsSummary()))
        }
        add("open", "Open Swoop Shield", "Settings, lists, query log and rules", "shield", ["settings", "log", "lists"]) {
            SettingsWindow.show(tab: .shield)
        }
        add("update-lists", "Update Filter Lists", "Download the latest lists now", "arrow.triangle.2.circlepath", ["update", "refresh", "lists"]) {
            S.lists.update(force: true)
            Notifier.show("Updating filter lists…")
        }
        return c
    }
}

/// URL of the front tab in the browser that was frontmost before Swoop opened.
enum BrowserURL {
    static let chromium: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.google.Chrome.beta": "Google Chrome Beta", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "company.thebrowser.Browser": "Arc", "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera", "org.chromium.Chromium": "Chromium",
    ]

    static func frontmost() -> String? {
        let app = LauncherController.shared.previousApp ?? NSWorkspace.shared.frontmostApplication
        guard let id = app?.bundleIdentifier else { return nil }
        let script: String
        if id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview" {
            let name = id == "com.apple.Safari" ? "Safari" : "Safari Technology Preview"
            script = "tell application \"\(name)\" to return URL of front document"
        } else if let name = chromium[id] {
            script = "tell application \"\(name)\" to return URL of active tab of front window"
        } else {
            return nil   // Firefox has no AppleScript URL access; the command asks instead.
        }
        let (ok, out) = AppleScript.runReturning(script)
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ok && s.hasPrefix("http") ? s : nil
    }
}
