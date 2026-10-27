// SPDX-License-Identifier: MIT
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Space Lens: squarified treemap (Bruls, Huizing & van Wijk)

public struct TreemapTile: Equatable {
    public let index: Int      // index into the input values
    public let rect: CGRect
}

public enum Treemap {
    /// Lays `values` (any order, non-negative) into `rect`. Zero values get no tile.
    public static func layout(_ values: [Double], in rect: CGRect) -> [TreemapTile] {
        let items = values.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }
        let total = items.reduce(0) { $0 + $1.element }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        var remaining = items.map { (index: $0.offset, area: $0.element * scale) }
        var free = rect
        var out: [TreemapTile] = []
        while !remaining.isEmpty {
            let short = Double(min(free.width, free.height))
            var row: [(index: Int, area: Double)] = [remaining.removeFirst()]
            while let next = remaining.first, worst(row + [next], short) <= worst(row, short) {
                row.append(remaining.removeFirst())
            }
            let rowArea = row.reduce(0) { $0 + $1.area }
            if free.width >= free.height {
                // column on the left
                let w = CGFloat(rowArea / Double(free.height))
                var y = free.minY
                for r in row {
                    let h = CGFloat(r.area / Double(w))
                    out.append(TreemapTile(index: r.index, rect: CGRect(x: free.minX, y: y, width: w, height: h)))
                    y += h
                }
                free = CGRect(x: free.minX + w, y: free.minY, width: max(0, free.width - w), height: free.height)
            } else {
                let h = CGFloat(rowArea / Double(free.width))
                var x = free.minX
                for r in row {
                    let w = CGFloat(r.area / Double(h))
                    out.append(TreemapTile(index: r.index, rect: CGRect(x: x, y: free.minY, width: w, height: h)))
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: max(0, free.height - h))
            }
        }
        return out
    }

    static func worst(_ row: [(index: Int, area: Double)], _ side: Double) -> Double {
        let s = row.reduce(0) { $0 + $1.area }
        guard s > 0, side > 0 else { return .infinity }
        let mx = row.map { $0.area }.max()!, mn = row.map { $0.area }.min()!
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }
}

/// A node of the disk-usage tree (Space Lens). Built on macOS by the scanner.
public final class DiskNode: Identifiable {
    public let id = UUID()
    public let name: String
    public let path: String
    public var size: Int64
    public var isDirectory: Bool
    public var children: [DiskNode]

    public init(name: String, path: String, size: Int64, isDirectory: Bool, children: [DiskNode] = []) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.children = children
    }

    /// Children for display: the largest `limit`, the rest folded into one "Other" node.
    public func displayChildren(limit: Int = 40) -> [DiskNode] {
        let sorted = children.sorted { $0.size > $1.size }
        guard sorted.count > limit else { return sorted }
        let rest = sorted[limit...]
        let other = DiskNode(name: "\(rest.count) smaller items", path: path, size: rest.reduce(0) { $0 + $1.size },
                             isDirectory: false)
        return Array(sorted.prefix(limit)) + [other]
    }
}

// MARK: - Security check (adware / malware persistence)

public struct PersistenceItem: Equatable {
    public let path: String
    public let label: String?
    public let program: String?        // Program or ProgramArguments[0]
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let signedBy: String?       // team / authority, filled on macOS (nil = unsigned/unknown)
    public let programExists: Bool

    public init(path: String, label: String?, program: String?, arguments: [String] = [], runAtLoad: Bool = false,
                keepAlive: Bool = false, signedBy: String? = nil, programExists: Bool = true) {
        self.path = path
        self.label = label
        self.program = program
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.signedBy = signedBy
        self.programExists = programExists
    }
}

public struct SecurityFinding: Equatable, Identifiable {
    public enum Severity: Int, Comparable {
        case info = 0, review = 1, suspicious = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        public var title: String {
            switch self {
            case .info: return "OK"
            case .review: return "Review"
            case .suspicious: return "Suspicious"
            }
        }
    }

    public var id: String { path }
    public let path: String
    public let severity: Severity
    public let title: String
    public let reasons: [String]       // plain-English explanation of every signal
}

/// Heuristics, not signatures: Swoop explains *why* something looks off and lets the
/// user decide. Nothing is removed automatically.
public enum PersistenceAnalyzer {
    /// Known adware family name fragments (seen in public reports by Objective-See,
    /// Malwarebytes, Apple XProtect rule names). Matching is on label/program path.
    public static let adwareMarkers = [
        "genieo", "installmac", "vsearch", "conduit", "spigot", "pirrit", "crossrider", "bundlore", "shlayer",
        "adload", "mughthesec", "advancedmaccleaner", "mackeeper", "searchmine", "searchbaron", "chumsearch",
        "mapsfinder", "webtools", "safefinder", "operativeupdater", "systemupdate.agent", "zeusearch",
        "launchsetup", "macsearch", "searchpulse", "dataplex", "tapeline", "aqua-search", "macshield",
        "cleanupmac", "macbooster", "mykotlerino", "geneio", "updater.mac.app", "downlite", "slimupdater",
    ]

    static let suspiciousDirs = ["/tmp/", "/private/tmp/", "/var/tmp/", "/users/shared/", "/library/application support/.",
                                 "/.", "/private/var/folders/"]
    static let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/python", "/usr/bin/python3",
                         "/usr/bin/osascript", "/usr/bin/perl", "/usr/bin/ruby", "/usr/bin/curl", "/usr/bin/env"]

    public static func analyze(_ item: PersistenceItem) -> SecurityFinding {
        var reasons: [String] = []
        var sev = SecurityFinding.Severity.info
        func flag(_ s: SecurityFinding.Severity, _ r: String) { reasons.append(r); if s > sev { sev = s } }

        let label = item.label ?? (item.path as NSString).lastPathComponent
        let prog = (item.program ?? item.arguments.first ?? "")
        let hay = (label + " " + prog + " " + item.arguments.joined(separator: " ")).lowercased()

        if let m = adwareMarkers.first(where: { hay.contains($0) }) {
            flag(.suspicious, "Its name or program matches a known adware family (\"\(m)\").")
        }
        let lowerProg = prog.lowercased()
        if suspiciousDirs.contains(where: { lowerProg.contains($0) }) {
            flag(.suspicious, "It runs a program from a temporary or hidden folder (\(prog)), which legitimate software rarely does.")
        }
        if shells.contains(where: { lowerProg == $0 }) {
            let script = item.arguments.dropFirst().joined(separator: " ")
            if script.contains("curl") || script.contains("base64") || script.contains("eval") || script.contains("http") {
                flag(.suspicious, "It starts a shell/interpreter that downloads or decodes code at launch (\(String(script.prefix(80))))")
            } else {
                flag(.review, "It runs a script through \(prog) instead of a signed app or tool.")
            }
        }
        if !item.programExists && !prog.isEmpty {
            flag(.review, "The program it points to no longer exists — usually a leftover from an uninstalled app. Safe to remove.")
        }
        if item.signedBy == nil && !prog.isEmpty && item.programExists && !lowerProg.hasPrefix("/system/") && !lowerProg.hasPrefix("/usr/") {
            flag(.review, "The program isn't signed by an identified developer.")
        }
        if let l = item.label, !item.path.lowercased().hasSuffix(l.lowercased() + ".plist") {
            flag(.review, "The file name doesn't match its label (\(l)); some adware disguises itself this way.")
        }
        let random = label.split(separator: ".").last.map(String.init) ?? label
        if random.count >= 12, random.allSatisfy({ $0.isLetter || $0.isNumber }),
           random.filter({ $0.isNumber }).count >= 3, random.lowercased() == random {
            flag(.review, "Its name looks randomly generated (\(random)).")
        }
        if reasons.isEmpty {
            reasons.append(item.signedBy.map { "Signed by \($0). Nothing unusual found." } ?? "Nothing unusual found.")
        }
        if item.keepAlive && sev >= .review {
            reasons.append("It is set to restart itself if stopped (KeepAlive).")
        }
        return SecurityFinding(path: item.path, severity: sev, title: label, reasons: reasons)
    }

    /// Browser extensions: flags names matching adware markers.
    public static func analyzeExtension(name: String, id: String, path: String) -> SecurityFinding {
        let hay = (name + " " + id).lowercased()
        let squashed = hay.replacingOccurrences(of: " ", with: "")
        if let m = adwareMarkers.first(where: { hay.contains($0) || squashed.contains($0) }) {
            return SecurityFinding(path: path, severity: .suspicious, title: name,
                                   reasons: ["The extension's name matches a known adware family (\"\(m)\")."])
        }
        let searchy = ["search", "maps", "pdf converter", "weather", "tab", "shopping", "coupon"]
        if searchy.contains(where: { hay.contains($0) }) {
            return SecurityFinding(path: path, severity: .review, title: name,
                                   reasons: ["Search, coupon and converter extensions are the most common way adware hijacks a browser. Keep it only if you installed it on purpose."])
        }
        return SecurityFinding(path: path, severity: .info, title: name, reasons: ["Nothing unusual found."])
    }

    /// Where persistence lives. User-domain items can be removed by Swoop; the rest
    /// need an administrator and are shown with a Reveal button.
    public static let locations = [
        "~/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/StartupItems", "/Library/PrivilegedHelperTools", "~/Library/Application Support/com.apple.backgroundtaskmanagementagent",
    ]
}

// MARK: - App updates

public enum VersionCompare {
    /// Numeric dot-separated compare ("1.10" > "1.9"; "2.0" == "2"). Trailing non-numeric
    /// parts ("b3") compare as text.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [String] {
            s.trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: "v", with: "", options: .anchored)
                .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" || $0 == " " || $0 == "," }).map(String.init)
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : "0", y = i < pb.count ? pb[i] : "0"
            if let ix = Int(x), let iy = Int(y) {
                if ix != iy { return ix < iy ? .orderedAscending : .orderedDescending }
            } else if x != y {
                return x < y ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }
}

public struct AvailableUpdate: Equatable {
    public enum Source: String { case sparkle = "Sparkle feed", homebrew = "Homebrew cask", appStore = "App Store" }
    public let bundleID: String
    public let appName: String
    public let installed: String
    public let latest: String
    public let source: Source
    public let downloadURL: String?
}

/// Minimal Sparkle appcast reader: newest item's version (sparkle:shortVersionString,
/// falling back to sparkle:version) and enclosure URL. Regex-based so it runs on Linux
/// without FoundationXML.
public enum Appcast {
    public static func latest(in xml: String) -> (version: String, url: String?)? {
        var best: (String, String?)?
        let items = xml.components(separatedBy: "<item").dropFirst()
        for item in items {
            let v = attrOrTag(item, "sparkle:shortVersionString") ?? attrOrTag(item, "sparkle:version")
            guard let version = v else { continue }
            let url = attr(item, tag: "enclosure", name: "url")
            if best == nil || VersionCompare.isNewer(version, than: best!.0) { best = (version, url) }
        }
        return best
    }

    static func attrOrTag(_ s: String, _ name: String) -> String? {
        if let r = s.range(of: "<\(name)>"), let e = s.range(of: "</\(name)>", range: r.upperBound..<s.endIndex) {
            return String(s[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let r = s.range(of: "\(name)=\"") , let e = s[r.upperBound...].firstIndex(of: "\"") {
            return String(s[r.upperBound..<e])
        }
        return nil
    }

    static func attr(_ s: String, tag: String, name: String) -> String? {
        guard let t = s.range(of: "<\(tag)") else { return nil }
        let rest = s[t.upperBound...]
        guard let end = rest.firstIndex(of: ">") else { return nil }
        let inside = String(rest[..<end])
        guard let r = inside.range(of: " \(name)=\"") ?? inside.range(of: "\n\(name)=\"") ?? inside.range(of: "\t\(name)=\""),
              let q = inside[r.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(inside[r.upperBound..<q])
    }
}

/// Homebrew cask API (formulae.brew.sh/api/cask.json) entries we need.
public struct CaskInfo: Equatable {
    public let token: String
    public let version: String
    public let appNames: [String]   // "Visual Studio Code.app"
    public let homepage: String?

    public static func parse(_ data: Data) -> [CaskInfo] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { c in
            guard let token = c["token"] as? String, let version = c["version"] as? String else { return nil }
            var apps: [String] = []
            for a in (c["artifacts"] as? [[String: Any]]) ?? [] {
                for v in (a["app"] as? [Any]) ?? [] { if let s = v as? String { apps.append(s) } }
            }
            return CaskInfo(token: token, version: version.components(separatedBy: ",").first ?? version,
                            appNames: apps, homepage: c["homepage"] as? String)
        }
    }
}

// MARK: - Maintenance

public struct MaintenanceTask: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let explanation: String
    public let command: String        // run through /bin/sh (with admin rights when needsAdmin)
    public let needsAdmin: Bool

    public static let all: [MaintenanceTask] = [
        MaintenanceTask(id: "flush-dns", title: "Flush DNS cache",
                        explanation: "Clears cached website addresses. Fixes sites that moved servers or won't load after a network change. Harmless: the cache refills as you browse.",
                        command: "dscacheutil -flushcache; killall -HUP mDNSResponder", needsAdmin: true),
        MaintenanceTask(id: "reindex-spotlight", title: "Reindex Spotlight",
                        explanation: "Rebuilds the search index for your startup disk. Fixes missing or stale search results. Spotlight is slower for a while (minutes to hours) as it re-reads the disk.",
                        command: "mdutil -E /", needsAdmin: true),
        MaintenanceTask(id: "rebuild-launch-services", title: "Rebuild Launch Services database",
                        explanation: "Fixes duplicate apps in \"Open With\" menus and wrong default apps. Your default-app choices for file types may need setting again.",
                        command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user",
                        needsAdmin: false),
        MaintenanceTask(id: "periodic-scripts", title: "Run maintenance scripts",
                        explanation: "Runs the daily, weekly and monthly housekeeping scripts macOS normally runs overnight (log rotation, temporary file cleanup).",
                        command: "periodic daily weekly monthly", needsAdmin: true),
        MaintenanceTask(id: "free-purgeable", title: "Free up RAM (purge)",
                        explanation: "Asks macOS to drop disk caches from memory. Memory pressure drops briefly; apps may feel slower for a moment while caches refill. Not needed on a healthy Mac.",
                        command: "purge", needsAdmin: true),
        MaintenanceTask(id: "quicklook-reset", title: "Reset Quick Look",
                        explanation: "Clears Quick Look's preview cache and restarts it. Fixes blank or outdated previews.",
                        command: "qlmanage -r && qlmanage -r cache", needsAdmin: false),
        MaintenanceTask(id: "restart-dock-finder", title: "Restart Dock and Finder",
                        explanation: "Restarts the Dock and Finder. Fixes a frozen Dock or desktop. Open Finder windows will close.",
                        command: "killall Dock; killall Finder", needsAdmin: false),
    ]
}

// MARK: - Battery

public struct BatteryHealth: Equatable {
    public let cycleCount: Int?
    public let designCapacity: Int?      // mAh
    public let maxCapacity: Int?         // mAh (full charge capacity)
    public let currentCharge: Int?       // %
    public let isCharging: Bool
    public let condition: String?        // "Normal" / "Service Recommended"
    public let temperatureC: Double?

    public var healthPercent: Int? {
        guard let d = designCapacity, d > 0, let m = maxCapacity else { return nil }
        return min(100, Int((Double(m) / Double(d) * 100).rounded()))
    }

    /// Parses `ioreg -r -c AppleSmartBattery -a`-style key/value text (the plain `ioreg -rn
    /// AppleSmartBattery` form: lines like `"CycleCount" = 123`).
    public static func parse(ioreg text: String) -> BatteryHealth? {
        func int(_ key: String) -> Int? {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("\"\(key)\" = ") { return Int(t.dropFirst(key.count + 5).trimmingCharacters(in: .whitespaces)) }
            }
            return nil
        }
        func bool(_ key: String) -> Bool {
            text.contains("\"\(key)\" = Yes")
        }
        guard text.contains("AppleSmartBattery") || int("CycleCount") != nil else { return nil }
        let maxCap = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        let current = int("CurrentCapacity")
        let maxPct = int("MaxCapacity")
        let pct: Int? = {
            guard let c = current else { return nil }
            if let m = maxPct, m > 0, m <= 100 { return c }          // Apple Silicon reports %
            if let m = maxPct, m > 100 { return Int(Double(c) / Double(m) * 100) }
            return c
        }()
        let temp = int("Temperature").map { Double($0) / 100.0 }
        return BatteryHealth(cycleCount: int("CycleCount"), designCapacity: int("DesignCapacity"), maxCapacity: maxCap,
                             currentCharge: pct, isCharging: bool("IsCharging"), condition: nil, temperatureC: temp)
    }
}

// MARK: - Restore log (undo for everything Swoop removes)

public struct RemovalRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var originalPath: String
    public var trashedPath: String?   // nil = deleted permanently (can't be restored)
    public var size: Int64
    public var module: String         // "System Junk", "Uninstaller", …
    public var reason: String         // the "why this is safe" note shown at the time
    public var restored: Bool

    public init(id: UUID = UUID(), date: Date = Date(), originalPath: String, trashedPath: String?, size: Int64,
                module: String, reason: String, restored: Bool = false) {
        self.id = id
        self.date = date
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.size = size
        self.module = module
        self.reason = reason
        self.restored = restored
    }

    public var canRestore: Bool { trashedPath != nil && !restored }
}

public struct RemovalLog: Codable, Equatable {
    public private(set) var records: [RemovalRecord] = []
    public var maxRecords = 5000

    public init() {}

    public mutating func append(_ r: RemovalRecord) {
        records.insert(r, at: 0)
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
    }

    public mutating func markRestored(_ id: UUID) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].restored = true }
    }

    /// Records grouped by clean-up session (same module, within `gap` seconds).
    public func sessions(gap: TimeInterval = 120) -> [[RemovalRecord]] {
        var out: [[RemovalRecord]] = []
        for r in records {
            if let last = out.last?.last, last.module == r.module, abs(last.date.timeIntervalSince(r.date)) <= gap {
                out[out.count - 1].append(r)
            } else {
                out.append([r])
            }
        }
        return out
    }
}

// MARK: - Scheduled clean-ups

public struct CleanupSchedule: Codable, Equatable {
    public enum Frequency: String, Codable, CaseIterable { case off, daily, weekly, monthly }
    public var frequency: Frequency = .off
    public var hour = 10                    // local hour to run (when the Mac is awake)
    public var categories: [String] = [JunkCategory.userCaches.rawValue, JunkCategory.logs.rawValue,
                                       JunkCategory.brokenDownloads.rawValue]
    public var onlyIfOverBytes: Int64 = 500_000_000   // skip when there's less junk than this
    public var notify = true
    public var lastRun: Date?

    public init() {}

    /// Next run after `now` (nil when off). A run missed while asleep happens on wake.
    public func nextRun(after now: Date, calendar: Calendar = .current) -> Date? {
        guard frequency != .off else { return nil }
        let step: DateComponents
        switch frequency {
        case .daily: step = DateComponents(day: 1)
        case .weekly: step = DateComponents(day: 7)
        case .monthly: step = DateComponents(month: 1)
        case .off: return nil
        }
        guard let last = lastRun else {
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now).map { $0 > now ? $0 : now }
        }
        guard let next = calendar.date(byAdding: step, to: last),
              let atHour = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: next) else { return nil }
        return max(atHour, now)
    }

    public func isDue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let n = nextRun(after: now, calendar: calendar) else { return false }
        return n <= now
    }
}

// MARK: - "Why this is safe" notes

public enum SafetyNotes {
    public static func note(forRule id: String) -> String {
        switch id {
        case "user-caches":
            return "Apps keep caches to load things faster and rebuild them automatically when they're missing. Removing them frees space; an app may be a little slower the first time it opens. Apple's own caches and iCloud state are never touched."
        case "user-logs":
            return "Logs are diagnostic text that apps write as they run. No app needs old logs to work."
        case "xcode-deriveddata":
            return "Xcode's build products and indexes. Xcode rebuilds them on the next build (the first build takes longer)."
        case "xcode-archives":
            return "Archived app builds, including symbol files for crash reports. Keep these if you ship apps and need to symbolicate old crashes."
        case "xcode-device-support", "xcode-watch-support":
            return "Debug symbols copied from devices you've connected. Xcode copies them again when you next connect that device."
        case "simulator-caches":
            return "Caches for the iOS Simulator. Rebuilt automatically."
        case "broken-downloads":
            return "Downloads that never finished (older than a day, so nothing in progress). They can't be opened as they are."
        case "language-files":
            return "Translations for languages you don't use. Off by default: removing files from a signed app breaks its seal, which can stop some apps from updating or launching. Swoop never touches App Store or Apple apps."
        case "trash":
            return "Items you already moved to the Trash. Emptying it is permanent."
        default:
            if id.hasSuffix("-cache") { return "Browser caches are copies of web pages and images. The browser downloads them again as needed; you stay signed in (cookies and history aren't touched)." }
            return "Rebuilt automatically when needed."
        }
    }

    public static let leftover = "Settings, caches and support files named after this app's bundle ID. Without the app they do nothing; removing them also resets the app if you reinstall it."
    public static let orphan = "Named after an app that's no longer installed. Swoop checks every installed app and its helpers before listing it. Review before removing: some files belong to command-line tools or plug-ins."
    public static let largeFile = "Large files are never selected for you. Only you know whether a file is still needed."
    public static let duplicate = "Byte-for-byte identical copies (checked with SHA-256). Swoop keeps one copy of every group selected for you: the oldest."
}
