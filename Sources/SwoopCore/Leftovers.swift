// SPDX-License-Identifier: MIT
import Foundation

/// The app being uninstalled, as far as leftover matching needs.
public struct AppIdentity: Equatable {
    public let bundleID: String
    public let name: String          // display name, e.g. "Visual Studio Code"
    public let executableName: String?

    public init(bundleID: String, name: String, executableName: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.executableName = executableName
    }
}

public enum LeftoverMatch: String, Equatable {
    /// The entry is named after the bundle ID (strong evidence).
    case bundleID
    /// The entry is named exactly after the app (weaker; only for distinctive names).
    case appName
}

public enum LeftoverMatcher {
    /// Places in ~/Library where apps leave things behind.
    public static let libraryFolders = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost",
        "Library/Containers", "Library/Group Containers", "Library/LaunchAgents", "Library/Saved Application State",
        "Library/Logs", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies", "Library/Application Scripts",
        "Library/Application Support/CrashReporter",
    ]

    /// Folder names too generic to match by app name alone.
    public static let genericNames: Set<String> = [
        "google", "microsoft", "apple", "adobe", "mozilla", "application", "applications", "support", "data",
        "cache", "caches", "logs", "log", "updates", "update", "helper", "app", "settings", "preferences",
        "config", "temp", "tmp", "default", "user", "library", "documents", "web", "browser", "mac", "macos",
        "plugins", "plugin", "extensions", "crashreporter", "sync", "backup", "notes", "music", "photos",
        "mail", "calendar", "messages", "safari", "finder", "terminal", "preview", "books", "news",
    ]

    /// Suffixes Library entries add after the bundle ID.
    static let knownSuffixes = [".plist", ".savedState", ".binarycookies", ".lockfile", ".log"]

    public static func match(entryName raw: String, app: AppIdentity) -> LeftoverMatch? {
        let bid = app.bundleID.lowercased()
        guard bid.split(separator: ".").count >= 2 else { return nil }
        // Never attribute Apple's files to a third-party app.
        if raw.lowercased().hasPrefix("com.apple.") && !bid.hasPrefix("com.apple.") { return nil }
        let name = raw.lowercased()
        let stripped = stripSuffixes(name)
        if stripped == bid { return .bundleID }
        // com.foo.bar.helper, com.foo.bar.ShipIt, ByHost "com.foo.bar.<UUID>.plist"
        if stripped.hasPrefix(bid + ".") { return .bundleID }
        // Group containers: TEAMID.com.foo.bar / group.com.foo.bar
        if stripped.hasSuffix("." + bid) {
            let prefix = String(stripped.dropLast(bid.count + 1))
            if prefix == "group" || isTeamID(prefix) { return .bundleID }
        }
        // Group containers like TEAMID.com.foo.bar.shared
        if let dot = stripped.firstIndex(of: "."), isTeamID(String(stripped[..<dot])) || stripped.hasPrefix("group.") {
            let rest = String(stripped[stripped.index(after: dot)...])
            if rest == bid || rest.hasPrefix(bid + ".") { return .bundleID }
        }
        // By app name: exact (case-insensitive) and distinctive.
        for candidate in [app.name, app.executableName].compactMap({ $0?.lowercased() }) {
            if candidate.count >= 4 && !genericNames.contains(candidate) && name == candidate {
                return .appName
            }
        }
        return nil
    }

    static func stripSuffixes(_ s: String) -> String {
        var out = s
        var changed = true
        while changed {
            changed = false
            for suf in knownSuffixes.map({ $0.lowercased() }) where out.hasSuffix(suf) && out.count > suf.count {
                out = String(out.dropLast(suf.count))
                changed = true
            }
        }
        return out
    }

    /// Apple Developer Team IDs are 10 letters/digits (with at least one digit), e.g. UBF8T346G9.
    static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && s.contains(where: { $0.isNumber }) && !reverseDNSRoots.contains(s.lowercased())
    }

    static let reverseDNSRoots: Set<String> = [
        "com", "org", "net", "io", "de", "co", "app", "dev", "me", "uk", "fr", "jp", "cn", "ru", "info", "us",
        "ca", "ch", "nl", "se", "tv", "it", "es", "au", "at", "be", "dk", "fi", "no", "pl", "cz", "in", "br",
        "ai", "so", "sh", "is", "cc", "ly", "eu",
    ]

    /// "com.foo.Bar.plist" → "com.foo.bar"; "ABCDE12345.com.foo.bar" → "com.foo.bar";
    /// "group.com.foo" → "com.foo". nil when the name doesn't look like a bundle ID.
    public static func bundleID(fromEntryName raw: String) -> String? {
        var s = stripSuffixes(raw.lowercased())
        if s.hasPrefix("group.") { s = String(s.dropFirst(6)) }
        let comps = s.split(separator: ".").map(String.init)
        guard comps.count >= 2 else { return nil }
        var parts = comps
        if isTeamID(comps[0]) {
            parts = Array(comps.dropFirst())
        }
        guard parts.count >= 3, reverseDNSRoots.contains(parts[0]) else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }) else {
            return nil
        }
        // Drop a trailing UUID-ish component (ByHost prefs).
        if let last = parts.last, last.count >= 32, last.filter({ $0 == "-" }).count >= 4 {
            parts.removeLast()
        }
        return parts.joined(separator: ".")
    }

    /// Is this Library entry left over from an app that is no longer installed?
    /// `installed` holds lower-cased bundle IDs of every installed app (and helpers).
    public static func isOrphan(entryName: String, installed: Set<String>) -> Bool {
        guard let bid = bundleID(fromEntryName: entryName) else { return false }
        if bid.hasPrefix("com.apple.") || bid.hasPrefix("com.swoopkey.") { return false }
        if installed.contains(bid) { return false }
        for i in installed {
            // helper of an installed app, or a vendor prefix of one
            if bid.hasPrefix(i + ".") || i.hasPrefix(bid + ".") { return false }
        }
        // Same vendor + product root as an installed app (com.foo.bar-helper vs com.foo.bar).
        let comps = bid.split(separator: ".")
        if comps.count >= 3 {
            let vendorProduct = comps.prefix(3).joined(separator: ".")
            if installed.contains(where: { $0 == vendorProduct || $0.hasPrefix(vendorProduct + ".") }) { return false }
        }
        return true
    }
}
