// SPDX-License-Identifier: MIT
import AppKit
import SwoopCore

// MARK: - Login items & launch agents

struct LaunchItem: Identifiable {
    enum Domain: String { case user = "Your Launch Agents", allUsersAgent = "Launch Agents (all users)", daemon = "Launch Daemons (system)" }
    var id: String { path }
    let path: String
    let label: String
    let program: String?
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let domain: Domain
    var disabled: Bool
    var programExists: Bool {
        guard let p = program, p.hasPrefix("/") else { return true }
        return FileManager.default.fileExists(atPath: p)
    }
}

enum LaunchItems {
    static var uid: String { String(getuid()) }

    static func load() -> [LaunchItem] {
        let userDisabled = LaunchctlParser.disabledServices(Shell.output("/bin/launchctl", ["print-disabled", "gui/\(uid)"]) ?? "")
        let sysDisabled = LaunchctlParser.disabledServices(Shell.output("/bin/launchctl", ["print-disabled", "system"]) ?? "")
        var out: [LaunchItem] = []
        let dirs: [(String, LaunchItem.Domain)] = [(NSHomeDirectory() + "/Library/LaunchAgents", .user),
                                                   ("/Library/LaunchAgents", .allUsersAgent),
                                                   ("/Library/LaunchDaemons", .daemon)]
        for (dir, domain) in dirs {
            for name in JunkScanner.list(dir) where name.hasSuffix(".plist") {
                let p = (dir as NSString).appendingPathComponent(name)
                guard let d = NSDictionary(contentsOfFile: p) as? [String: Any] else { continue }
                let label = d["Label"] as? String ?? String(name.dropLast(6))
                let args = d["ProgramArguments"] as? [String] ?? []
                let keep: Bool = (d["KeepAlive"] as? Bool) ?? (d["KeepAlive"] is [String: Any])
                let disabledMap = domain == .daemon ? sysDisabled : userDisabled
                let disabled = disabledMap[label] ?? ((d["Disabled"] as? Bool) ?? false)
                out.append(LaunchItem(path: p, label: label, program: d["Program"] as? String ?? args.first, arguments: args,
                                      runAtLoad: d["RunAtLoad"] as? Bool ?? false, keepAlive: keep, domain: domain, disabled: disabled))
            }
        }
        return out
    }

    /// Enable/disable without deleting anything (launchctl's own override database).
    static func setEnabled(_ item: LaunchItem, _ enabled: Bool) -> String? {
        switch item.domain {
        case .user, .allUsersAgent:
            let target = "gui/\(uid)/\(item.label)"
            if enabled {
                Shell.run("/bin/launchctl", ["enable", target])
                Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", item.path])
            } else {
                Shell.run("/bin/launchctl", ["bootout", target])
                Shell.run("/bin/launchctl", ["disable", target])
            }
            return nil
        case .daemon:
            let label = item.label.replacingOccurrences(of: "'", with: "")
            let path = item.path.replacingOccurrences(of: "'", with: "")
            let cmd = enabled
                ? "launchctl enable system/'\(label)'; launchctl bootstrap system '\(path)' || true"
                : "launchctl bootout system/'\(label)' || true; launchctl disable system/'\(label)'"
            let (ok, out) = Shell.runAsAdmin(cmd, prompt: "Swoop wants to \(enabled ? "enable" : "disable") \(item.label).")
            return ok ? nil : out
        }
    }

    /// Removes a user agent (stops it, then Trash via FileRemover). System items need an
    /// administrator and are moved to your Trash with `mv` (still listed in the restore log).
    static func remove(_ item: LaunchItem, reason: String) -> String? {
        if item.domain == .user {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])
            let r = FileRemover.shared.remove([URL(fileURLWithPath: item.path)], module: "Login Items", defaultReason: reason)
            return r.failures.first?.reason
        }
        let path = item.path.replacingOccurrences(of: "'", with: "")
        let dest = NSHomeDirectory() + "/.Trash/" + (path as NSString).lastPathComponent
        let domain = item.domain == .daemon ? "system" : "gui/\(uid)"
        let cmd = "launchctl bootout \(domain) '\(path)' 2>/dev/null; mv '\(path)' '\(dest.replacingOccurrences(of: "'", with: ""))'"
        let (ok, out) = Shell.runAsAdmin(cmd, prompt: "Swoop wants to remove \(item.label).")
        if ok { FileRemover.shared.record(URL(fileURLWithPath: item.path), trashed: dest, size: 0, module: "Security", reason: reason); FileRemover.shared.save() }
        return ok ? nil : out
    }

    /// Legacy "Open at Login" items (System Events).
    static func loginItemNames() -> [String] {
        let (ok, out) = AppleScript.runReturning("tell application \"System Events\" to get the name of every login item")
        guard ok, !out.isEmpty else { return [] }
        return out.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    static func removeLoginItem(_ name: String) -> Bool {
        AppleScript.run("tell application \"System Events\" to delete login item \"\(name.replacingOccurrences(of: "\"", with: ""))\"")
    }
}

// MARK: - Security check

struct LaunchFinding: Identifiable {
    let item: LaunchItem
    let finding: SecurityFinding
    var id: String { item.path }
}

struct ExtensionFinding: Identifiable {
    let browser: String
    let finding: SecurityFinding
    var id: String { browser + finding.path }
}

struct SecurityReport {
    var launch: [LaunchFinding] = []
    var extensions: [ExtensionFinding] = []
    var proxy: String?
    var xprotectVersion: String?
}

enum SecurityScanner {
    static func scan() -> SecurityReport {
        var r = SecurityReport()
        for item in LaunchItems.load() {
            let signer = item.program.flatMap { $0.hasPrefix("/") ? CodeSign.signer(of: $0) : nil }
            let p = PersistenceItem(path: item.path, label: item.label, program: item.program, arguments: item.arguments,
                                    runAtLoad: item.runAtLoad, keepAlive: item.keepAlive, signedBy: signer,
                                    programExists: item.programExists)
            r.launch.append(LaunchFinding(item: item, finding: PersistenceAnalyzer.analyze(p)))
        }
        r.launch.sort { $0.finding.severity > $1.finding.severity }
        r.extensions = browserExtensions().sorted { $0.finding.severity > $1.finding.severity }
        r.proxy = proxySummary()
        if let d = NSDictionary(contentsOfFile: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist") {
            r.xprotectVersion = d["CFBundleShortVersionString"] as? String
        }
        return r
    }

    static func browserExtensions() -> [ExtensionFinding] {
        let home = NSHomeDirectory()
        var out: [ExtensionFinding] = []
        let chromium: [(String, String)] = [("Chrome", "Google/Chrome"), ("Brave", "BraveSoftware/Brave-Browser"),
                                            ("Edge", "Microsoft Edge"), ("Arc", "Arc/User Data"), ("Vivaldi", "Vivaldi")]
        for (browser, sub) in chromium {
            let base = home + "/Library/Application Support/" + sub
            for profile in JunkScanner.list(base) where profile == "Default" || profile.hasPrefix("Profile ") {
                let extDir = base + "/" + profile + "/Extensions"
                for id in JunkScanner.list(extDir) where id.count == 32 {
                    guard let ver = JunkScanner.list(extDir + "/" + id).sorted().last else { continue }
                    let dir = extDir + "/" + id + "/" + ver
                    guard let m = readJSON(dir + "/manifest.json") else { continue }
                    var name = m["name"] as? String ?? id
                    if name.hasPrefix("__MSG_") { name = localized(name, dir: dir, defaultLocale: m["default_locale"] as? String) }
                    if id == "nmmhkkegccagdldgiimedpiccmgmieda" || id == "ghbmnnjooekpmoecnnnilnnbdlolhkhi" { continue } // Google's own
                    out.append(ExtensionFinding(browser: browser, finding: PersistenceAnalyzer.analyzeExtension(name: name, id: id, path: dir)))
                }
            }
        }
        let ff = home + "/Library/Application Support/Firefox/Profiles"
        for profile in JunkScanner.list(ff) {
            guard let j = readJSON(ff + "/" + profile + "/extensions.json"), let addons = j["addons"] as? [[String: Any]] else { continue }
            for a in addons where (a["type"] as? String) == "extension" && (a["location"] as? String) == "app-profile" {
                let name = (a["defaultLocale"] as? [String: Any])?["name"] as? String ?? a["id"] as? String ?? "?"
                out.append(ExtensionFinding(browser: "Firefox", finding: PersistenceAnalyzer.analyzeExtension(
                    name: name, id: a["id"] as? String ?? "", path: a["path"] as? String ?? ff)))
            }
        }
        return out
    }

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func localized(_ msg: String, dir: String, defaultLocale: String?) -> String {
        let key = String(msg.dropFirst(6).dropLast(2))
        for loc in [defaultLocale ?? "en", "en", "en_US", "en_GB"] {
            if let m = readJSON(dir + "/_locales/" + loc + "/messages.json") {
                for (k, v) in m where k.lowercased() == key.lowercased() {
                    if let s = (v as? [String: Any])?["message"] as? String { return s }
                }
            }
        }
        return key
    }

    /// Adware often sets a system proxy or PAC file to intercept browsing.
    static func proxySummary() -> String? {
        guard let out = Shell.output("/usr/sbin/scutil", ["--proxy"]) else { return nil }
        var parts: [String] = []
        if out.contains("HTTPEnable : 1") { parts.append("HTTP proxy") }
        if out.contains("HTTPSEnable : 1") { parts.append("HTTPS proxy") }
        if out.contains("ProxyAutoConfigEnable : 1") { parts.append("automatic proxy (PAC) file") }
        if out.contains("SOCKSEnable : 1") { parts.append("SOCKS proxy") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - App updates

enum UpdateChecker {
    struct Row: Identifiable {
        var id: String { app.path }
        let app: InstalledApp
        let installed: String
        var latest: String?
        var source: AvailableUpdate.Source?
        var url: String?
        var caskToken: String?
        var hasUpdate: Bool { latest.map { VersionCompare.isNewer($0, than: installed) } ?? false }
    }

    static func check(progress: @escaping (Int, Int) -> Void, done: @escaping ([Row]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = Providers.scanApps().filter { !$0.path.hasPrefix("/System") && !($0.bundleID ?? "").hasPrefix("com.apple.") }
            var initial: [Row] = []
            for a in apps {
                let info = NSDictionary(contentsOfFile: a.path + "/Contents/Info.plist") as? [String: Any] ?? [:]
                let v = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "?"
                initial.append(Row(app: a, installed: v))
            }
            let rows = Box(initial)
            let finished = Box(0)
            let total = initial.count
            let casks = loadCasks()
            var caskByApp: [String: CaskInfo] = [:]
            for c in casks { for n in c.appNames { caskByApp[n.lowercased()] = c } }
            let lock = NSLock()
            let group = DispatchGroup()
            let sem = DispatchSemaphore(value: 6)
            for i in initial.indices {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    sem.wait()
                    defer { sem.signal(); group.leave() }
                    let r = initial[i]
                    var out = r
                    let info = NSDictionary(contentsOfFile: r.app.path + "/Contents/Info.plist") as? [String: Any] ?? [:]
                    if FileManager.default.fileExists(atPath: r.app.path + "/Contents/_MASReceipt"), let bid = r.app.bundleID,
                       let store = appStoreLatest(bid) {
                        out.latest = store.0; out.source = .appStore; out.url = store.1
                    } else if let feed = info["SUFeedURL"] as? String, let u = URL(string: feed), u.scheme == "https",
                              let xml = fetch(u).flatMap({ String(data: $0, encoding: .utf8) }), let l = Appcast.latest(in: xml) {
                        out.latest = l.version; out.source = .sparkle; out.url = l.url
                    } else if let c = caskByApp[(r.app.path as NSString).lastPathComponent.lowercased()] {
                        out.latest = c.version; out.source = .homebrew; out.url = c.homepage; out.caskToken = c.token
                    }
                    lock.lock(); rows.value[i] = out; finished.value += 1; let f = finished.value; lock.unlock()
                    DispatchQueue.main.async { progress(f, total) }
                }
            }
            group.wait()
            let sorted = rows.value.sorted { ($0.hasUpdate ? 0 : 1, $0.app.name) < ($1.hasUpdate ? 0 : 1, $1.app.name) }
            DispatchQueue.main.async { done(sorted) }
        }
    }

    static func fetch(_ u: URL, timeout: TimeInterval = 12) -> Data? {
        let result = Box<Data?>(nil)
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.setValue("Swoop/0.1 (+https://swoopkey.com)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            if let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) { result.value = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result.value
    }

    static func appStoreLatest(_ bundleID: String) -> (String, String?)? {
        guard let u = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)&entity=macSoftware"),
              let d = fetch(u), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let first = (o["results"] as? [[String: Any]])?.first, let v = first["version"] as? String else { return nil }
        return (v, first["trackViewUrl"] as? String)
    }

    /// Homebrew's public cask index, cached for a day.
    static func loadCasks() -> [CaskInfo] {
        let cache = AppPaths.file("cask-cache.json")
        if let a = try? FileManager.default.attributesOfItem(atPath: cache.path), let m = a[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < 86400, let d = try? Data(contentsOf: cache) {
            return CaskInfo.parse(d)
        }
        guard let u = URL(string: "https://formulae.brew.sh/api/cask.json"), let d = fetch(u, timeout: 40) else { return [] }
        try? d.write(to: cache)
        return CaskInfo.parse(d)
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Maintenance

enum Maintenance {
    static func run(_ t: MaintenanceTask) {
        let detail = t.explanation + (t.needsAdmin ? "\n\nmacOS will ask for an administrator password." : "")
        guard Actions.confirm(t.title, detail + "\n\nCommand: \(t.command)", ok: "Run") else { return }
        Notifier.show("Running \(t.title)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok: Bool
            let output: String
            if t.needsAdmin {
                let r = Shell.runAsAdmin(t.command, prompt: "Swoop wants to run \"\(t.title)\".")
                ok = r.0
                output = r.1
            } else {
                let o = Shell.output("/bin/sh", ["-c", t.command + "; echo \"__exit=$?\""], timeout: 600) ?? ""
                ok = o.contains("__exit=0")
                output = o.replacingOccurrences(of: "__exit=0", with: "")
            }
            DispatchQueue.main.async {
                if ok { Notifier.show("\(t.title): done") } else { Actions.info("\(t.title) didn't finish", output.isEmpty ? "Cancelled." : output) }
                MaintenanceLog.record(t.id, ok: ok)
            }
        }
    }
}

enum MaintenanceLog {
    static func record(_ id: String, ok: Bool) {
        var d = UserDefaults.standard.dictionary(forKey: "maintenanceLastRun") as? [String: Double] ?? [:]
        if ok { d[id] = Date().timeIntervalSince1970 }
        UserDefaults.standard.set(d, forKey: "maintenanceLastRun")
    }

    static func lastRun(_ id: String) -> Date? {
        (UserDefaults.standard.dictionary(forKey: "maintenanceLastRun") as? [String: Double])?[id].map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - Battery

enum BatteryReader {
    static func read() -> BatteryHealth? {
        guard let io = Shell.output("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]), var b = BatteryHealth.parse(ioreg: io) else { return nil }
        if let sp = Shell.output("/usr/sbin/system_profiler", ["SPPowerDataType"]) {
            for line in sp.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Condition:") {
                    let c = t.dropFirst("Condition:".count).trimmingCharacters(in: .whitespaces)
                    b = BatteryHealth(cycleCount: b.cycleCount, designCapacity: b.designCapacity, maxCapacity: b.maxCapacity,
                                      currentCharge: b.currentCharge, isCharging: b.isCharging, condition: c, temperatureC: b.temperatureC)
                }
                if t.hasPrefix("Maximum Capacity:"), b.designCapacity == nil || b.maxCapacity == nil {
                    // Apple Silicon reports health as a percentage here.
                    let pct = Int(t.dropFirst("Maximum Capacity:".count).trimmingCharacters(in: CharacterSet(charactersIn: " %")))
                    if let p = pct {
                        b = BatteryHealth(cycleCount: b.cycleCount, designCapacity: 100, maxCapacity: p, currentCharge: b.currentCharge,
                                          isCharging: b.isCharging, condition: b.condition, temperatureC: b.temperatureC)
                    }
                }
            }
        }
        return b
    }
}

// MARK: - Privacy

struct PrivacyItem: Identifiable {
    let id: String
    let title: String
    let explanation: String
    let paths: [String]
    let browserBundleIDs: [String]
}

enum PrivacyCleaner {
    static var items: [PrivacyItem] {
        let h = NSHomeDirectory()
        let sfl = h + "/Library/Application Support/com.apple.sharedfilelist"
        let recents = JunkScanner.list(sfl).filter { $0.hasPrefix("com.apple.LSSharedFileList.Recent") }.map { sfl + "/" + $0 }
        let docRecents = JunkScanner.list(sfl + "/com.apple.LSSharedFileList.ApplicationRecentDocuments")
            .map { sfl + "/com.apple.LSSharedFileList.ApplicationRecentDocuments/" + $0 }
        func chromium(_ sub: String) -> [String] {
            let base = h + "/Library/Application Support/" + sub
            return JunkScanner.list(base).filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .flatMap { p in ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal"].map { base + "/" + p + "/" + $0 } }
        }
        return [
            PrivacyItem(id: "recent-items", title: "Recent items (Apple menu, Finder, app Open Recent lists)",
                        explanation: "Lists of recently opened apps, documents and servers. The files themselves aren't touched.",
                        paths: recents + docRecents, browserBundleIDs: []),
            PrivacyItem(id: "safari-history", title: "Safari history (needs Full Disk Access)",
                        explanation: "Your Safari browsing history on this Mac. If Safari syncs with iCloud, clear it in Safari instead to remove it everywhere. Bookmarks, passwords and cookies are kept.",
                        paths: ["History.db", "History.db-shm", "History.db-wal"].map { h + "/Library/Safari/" + $0 },
                        browserBundleIDs: ["com.apple.Safari"]),
            PrivacyItem(id: "chrome-history", title: "Chrome history",
                        explanation: "Browsing history and the most-visited tiles. Bookmarks, passwords and cookies are kept; Chrome sync may bring history back.",
                        paths: chromium("Google/Chrome"), browserBundleIDs: ["com.google.Chrome"]),
            PrivacyItem(id: "brave-history", title: "Brave history", explanation: "Browsing history only. Bookmarks and passwords are kept.",
                        paths: chromium("BraveSoftware/Brave-Browser"), browserBundleIDs: ["com.brave.Browser"]),
            PrivacyItem(id: "edge-history", title: "Edge history", explanation: "Browsing history only. Bookmarks and passwords are kept.",
                        paths: chromium("Microsoft Edge"), browserBundleIDs: ["com.microsoft.edgemac"]),
        ]
    }

    static func existing(_ item: PrivacyItem) -> [URL] {
        item.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func runningBrowser(_ item: PrivacyItem) -> String? {
        NSWorkspace.shared.runningApplications.first { app in item.browserBundleIDs.contains(app.bundleIdentifier ?? "") }?.localizedName
    }
}
