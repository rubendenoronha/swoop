// SPDX-License-Identifier: MIT
import Foundation

/// The cleaner's last line of defence. Every path is checked here immediately before it
/// is moved to the Trash or deleted, whichever module produced it.
///
/// Policy: Swoop only ever removes things inside the user's home folder, plus app bundles
/// in /Applications (Uninstaller) and their localisation folders (opt-in). It never touches
/// system or SIP-protected locations, other users' folders, iCloud Drive, Keychains, Mail,
/// Messages, Photos libraries, iPhone backups, SSH/GPG keys, or Swoop's own data.
public struct PathSafety {
    public enum Verdict: Equatable {
        case allowed
        case denied(String)

        public var isAllowed: Bool { self == .allowed }
    }

    public let home: String

    public init(home: String) {
        var h = (home as NSString).standardizingPath
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        self.home = h
    }

    /// Absolute prefixes that are never touched.
    public static let systemPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/tmp", "/cores",
        "/dev", "/opt", "/Library", "/Network", "/Volumes", "/.vol", "/nix",
        "/Applications/Utilities", "/System/Applications",
    ]

    /// Relative to home: these folders and everything inside them are never touched.
    public static let protectedHomeSubtrees = [
        "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
        "Library/Messages", "Library/Application Support/MobileSync", "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB", "Library/Calendars", "Library/Safari/Bookmarks.plist",
        "Library/Application Support/Swoop", "Library/Group Containers/group.com.apple.notes",
        "Library/Containers/com.apple.Notes", "Library/Photos", "Library/Accounts", "Library/Cookies/Cookies.binarycookies",
        "Library/Preferences/com.apple.security", "Library/Sharing", "Library/IdentityServices",
        "Library/Daemon Containers", "Library/Biome", "Library/Trial",
        "Pictures/Photos Library.photoslibrary", "Music/Music", "Music/iTunes",
        ".ssh", ".gnupg", ".config/gcloud", ".aws", ".kube",
    ]

    /// Relative to home: the folder itself may not be deleted (its contents may).
    public static let protectedHomeFolders = [
        "", "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public",
        "Applications", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
        "Library/Containers", "Library/Group Containers", "Library/LaunchAgents", "Library/Saved Application State",
        "Library/Developer", "Library/Developer/Xcode", "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/Archives", "Library/Developer/CoreSimulator", ".Trash",
    ]

    /// `path` should already have symlinks resolved by the caller (the cleaner resolves
    /// them on macOS); `..` and `.` are normalised here as well.
    public func check(_ rawPath: String) -> Verdict {
        guard rawPath.hasPrefix("/") else { return .denied("not an absolute path") }
        let path = Self.normalize(rawPath)
        if path == "/" { return .denied("root") }
        // Pax (accountability blocker) is never touched, wherever it lives.
        if PaxProtection.isProtectedPath(path) { return .denied("part of Pax (protected)") }

        // App bundles in /Applications (one level, or one subfolder level).
        if path.hasPrefix("/Applications/") {
            return checkApplications(path)
        }
        for p in Self.systemPrefixes where path == p || path.hasPrefix(p + "/") {
            return .denied("system location \(p)")
        }
        guard path == home || path.hasPrefix(home + "/") else {
            return .denied("outside your home folder")
        }
        let rel = path == home ? "" : String(path.dropFirst(home.count + 1))
        if Self.protectedHomeFolders.contains(rel) {
            return .denied("protected folder ~/\(rel)")
        }
        for p in Self.protectedHomeSubtrees where rel == p || rel.hasPrefix(p + "/") {
            return .denied("protected data ~/\(p)")
        }
        // Apple's own containers and group containers hold system app data.
        let comps = rel.split(separator: "/").map(String.init)
        if comps.count >= 3, comps[0] == "Library", comps[1] == "Containers" || comps[1] == "Group Containers" {
            let name = comps[2]
            if name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.") || name.contains(".com.apple.") {
                return .denied("Apple container \(name)")
            }
        }
        return .allowed
    }

    private func checkApplications(_ path: String) -> Verdict {
        let rel = String(path.dropFirst("/Applications/".count))
        let comps = rel.split(separator: "/").map(String.init)
        guard let first = comps.first else { return .denied("/Applications itself") }
        if first == "Utilities" || first == "Safari.app" {
            return .denied("system app location")
        }
        // /Applications/X.app  or  /Applications/Folder/X.app
        if comps.count == 1, first.hasSuffix(".app") { return .allowed }
        if comps.count == 2, !first.hasSuffix(".app"), comps[1].hasSuffix(".app") { return .allowed }
        // Localisation folders inside an app (language files module, opt-in):
        // /Applications/X.app/Contents/Resources/xx.lproj
        if comps.count == 4, first.hasSuffix(".app"), comps[1] == "Contents", comps[2] == "Resources",
           comps[3].hasSuffix(".lproj"), comps[3] != "Base.lproj" {
            return .allowed
        }
        return .denied("inside an application bundle or /Applications")
    }

    public static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }
}
