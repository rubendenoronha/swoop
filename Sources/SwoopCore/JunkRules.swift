// SPDX-License-Identifier: MIT
import Foundation

public enum JunkCategory: String, CaseIterable, Codable, Identifiable {
    case userCaches, logs, xcode, brokenDownloads, browserCaches, languageFiles, trash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userCaches: return "User Caches"
        case .logs: return "Logs"
        case .xcode: return "Xcode Junk"
        case .brokenDownloads: return "Broken Downloads"
        case .browserCaches: return "Browser Caches"
        case .languageFiles: return "Language Files"
        case .trash: return "Trash"
        }
    }

    public var symbol: String {
        switch self {
        case .userCaches: return "internaldrive"
        case .logs: return "doc.text"
        case .xcode: return "hammer"
        case .brokenDownloads: return "arrow.down.circle"
        case .browserCaches: return "globe"
        case .languageFiles: return "character.bubble"
        case .trash: return "trash"
        }
    }
}

/// One place the junk scanner looks. `root` is relative to the home folder unless it
/// starts with "/". A root may contain "*" path components (expanded at scan time).
/// Each *child* of the root that passes include/exclude (and the age limit) is one item.
public struct JunkRule: Identifiable, Equatable {
    public let id: String
    public let category: JunkCategory
    public let title: String
    public let root: String
    public let include: [String]      // glob patterns on the child name; empty = everything
    public let exclude: [String]      // glob patterns on the child name
    public let defaultEnabled: Bool
    public let alwaysPermanent: Bool  // e.g. emptying the Trash can't go "to the Trash"
    public let minAgeDays: Int        // skip children modified more recently than this

    public init(id: String, category: JunkCategory, title: String, root: String, include: [String] = [],
                exclude: [String] = [], defaultEnabled: Bool = true, alwaysPermanent: Bool = false,
                minAgeDays: Int = 0) {
        self.id = id
        self.category = category
        self.title = title
        self.root = root
        self.include = include
        self.exclude = exclude
        self.defaultEnabled = defaultEnabled
        self.alwaysPermanent = alwaysPermanent
        self.minAgeDays = minAgeDays
    }

    public func includes(name: String) -> Bool {
        if name == ".DS_Store" || name == ".localized" { return false }
        if exclude.contains(where: { JunkRules.glob($0, matches: name) }) { return false }
        if include.isEmpty { return true }
        return include.contains(where: { JunkRules.glob($0, matches: name) })
    }
}

public enum JunkRules {
    /// Browser cache folders inside ~/Library/Caches: cleaned by the browser rule, so the
    /// generic cache rule skips them (no double counting).
    public static let browserCacheNames = [
        "Google", "BraveSoftware", "Microsoft Edge", "Arc", "company.thebrowser.Browser", "Firefox",
        "com.apple.Safari", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "Mozilla",
    ]

    /// Caches that hold state macOS or iCloud rely on, or Swoop itself: never cleaned.
    /// Apple's own caches are skipped wholesale in v0.1 (small, and some are not
    /// safe to drop while the system is running).
    public static let protectedCacheNames = [
        "com.apple.*", "CloudKit", "FamilyCircle", "com.swoopkey.swoop", "Swoop", "GeoServices",
        "com.crashlytics.data", "storeassetd", "*.mobileconfig",
    ]

    public static let all: [JunkRule] = [
        JunkRule(id: "user-caches", category: .userCaches, title: "Application caches", root: "Library/Caches",
                 exclude: protectedCacheNames + browserCacheNames),
        JunkRule(id: "user-logs", category: .logs, title: "User logs", root: "Library/Logs",
                 exclude: ["Swoop"]),
        JunkRule(id: "xcode-deriveddata", category: .xcode, title: "Xcode DerivedData",
                 root: "Library/Developer/Xcode/DerivedData"),
        JunkRule(id: "xcode-archives", category: .xcode, title: "Xcode Archives (keep if you need old dSYMs)",
                 root: "Library/Developer/Xcode/Archives", defaultEnabled: false),
        JunkRule(id: "xcode-device-support", category: .xcode, title: "iOS Device Support",
                 root: "Library/Developer/Xcode/iOS DeviceSupport"),
        JunkRule(id: "xcode-watch-support", category: .xcode, title: "watchOS Device Support",
                 root: "Library/Developer/Xcode/watchOS DeviceSupport"),
        JunkRule(id: "simulator-caches", category: .xcode, title: "Simulator caches",
                 root: "Library/Developer/CoreSimulator/Caches"),
        JunkRule(id: "broken-downloads", category: .brokenDownloads, title: "Unfinished downloads", root: "Downloads",
                 include: ["*.download", "*.crdownload", "*.part", "*.partial", "*.opdownload", "*.!ut", "*.tmp"],
                 minAgeDays: 1),
        JunkRule(id: "chrome-cache", category: .browserCaches, title: "Chrome cache", root: "Library/Caches/Google/Chrome"),
        JunkRule(id: "brave-cache", category: .browserCaches, title: "Brave cache",
                 root: "Library/Caches/BraveSoftware/Brave-Browser"),
        JunkRule(id: "edge-cache", category: .browserCaches, title: "Edge cache", root: "Library/Caches/Microsoft Edge"),
        JunkRule(id: "arc-cache", category: .browserCaches, title: "Arc cache", root: "Library/Caches/Arc"),
        JunkRule(id: "firefox-cache", category: .browserCaches, title: "Firefox cache",
                 root: "Library/Caches/Firefox/Profiles"),
        JunkRule(id: "safari-cache", category: .browserCaches, title: "Safari cache (needs Full Disk Access)",
                 root: "Library/Caches/com.apple.Safari"),
        JunkRule(id: "opera-cache", category: .browserCaches, title: "Opera cache", root: "Library/Caches/com.operasoftware.Opera"),
        JunkRule(id: "language-files", category: .languageFiles,
                 title: "Unused app localisations (off by default; can break some app signatures)",
                 root: "/Applications/*/Contents/Resources", include: ["*.lproj"], exclude: ["Base.lproj"],
                 defaultEnabled: false),
        JunkRule(id: "trash", category: .trash, title: "Items in the Trash (deleted permanently)", root: ".Trash",
                 defaultEnabled: false, alwaysPermanent: true),
    ]

    public static func rules(in category: JunkCategory) -> [JunkRule] { all.filter { $0.category == category } }

    /// Absolute root path(s) for a rule. "*" components are expanded by `list`, which
    /// returns the child names of a directory (empty if it doesn't exist).
    public static func expandRoot(_ rule: JunkRule, home: String, list: (String) -> [String]) -> [String] {
        let base = rule.root.hasPrefix("/") ? rule.root : (home as NSString).appendingPathComponent(rule.root)
        var paths = ["/"]
        for comp in base.split(separator: "/").map(String.init) {
            var next: [String] = []
            for p in paths {
                if comp.contains("*") || comp.contains("?") {
                    for child in list(p) where glob(comp, matches: child) {
                        next.append((p as NSString).appendingPathComponent(child))
                    }
                } else {
                    next.append((p as NSString).appendingPathComponent(comp))
                }
            }
            paths = next
        }
        return paths
    }

    /// Which rule (if any) claims this path as one of its items.
    public static func rule(forItem path: String, home: String, list: (String) -> [String] = { _ in [] }) -> JunkRule? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        for r in all {
            let roots: [String]
            if r.root.contains("*") {
                // Match the parent against the pattern directly.
                let pattern = r.root.hasPrefix("/") ? r.root : (home as NSString).appendingPathComponent(r.root)
                roots = globPath(pattern, matches: parent) ? [parent] : []
            } else {
                roots = expandRoot(r, home: home, list: list)
            }
            if roots.contains(parent) && r.includes(name: name) { return r }
        }
        return nil
    }

    /// Shell-style glob on a single name: `*` any run, `?` one character. Case-sensitive
    /// (APFS is usually case-insensitive, but folder names here come from listings).
    public static func glob(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        var pi = 0, ni = 0, starP = -1, starN = 0
        while ni < n.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == n[ni]) {
                pi += 1; ni += 1
            } else if pi < p.count && p[pi] == "*" {
                starP = pi; starN = ni; pi += 1
            } else if starP >= 0 {
                pi = starP + 1; starN += 1; ni = starN
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    static func globPath(_ pattern: String, matches path: String) -> Bool {
        let pc = pattern.split(separator: "/").map(String.init)
        let xc = path.split(separator: "/").map(String.init)
        guard pc.count == xc.count else { return false }
        return zip(pc, xc).allSatisfy { glob($0, matches: $1) }
    }
}

/// Which `.lproj` folders the language-files module may remove.
public enum LanguageFiles {
    /// Keeps Base, English, and every language in `preferred` (e.g. ["en-GB", "pt-PT"]).
    public static func shouldRemove(lproj name: String, preferred: [String]) -> Bool {
        guard name.hasSuffix(".lproj") else { return false }
        let lang = String(name.dropLast(6))
        if lang == "Base" || lang.isEmpty { return false }
        let keep = Set((["en"] + preferred).map(languageCode))
        let legacy: [String: String] = ["English": "en", "French": "fr", "German": "de", "Spanish": "es",
                                        "Italian": "it", "Japanese": "ja", "Dutch": "nl", "Portuguese": "pt"]
        let code = legacy[lang] ?? languageCode(lang)
        return !keep.contains(code)
    }

    static func languageCode(_ s: String) -> String {
        let lower = s.lowercased().replacingOccurrences(of: "_", with: "-")
        // zh-Hans / zh-Hant are different written languages: keep the script.
        if lower.hasPrefix("zh") {
            if lower.contains("hant") || lower.contains("tw") || lower.contains("hk") { return "zh-hant" }
            return "zh-hans"
        }
        return String(lower.split(separator: "-").first ?? Substring(lower))
    }
}
