// SPDX-License-Identifier: MIT
//
// Pax (paxpeace.com) is an accountability / adult-content blocker. Someone who installed it
// asked for it to be hard to remove, so Swoop's cleaner treats everything of Pax's as
// protected: the Uninstaller, Login Items, Security Check, Maintenance, Quit All / Force Quit
// and every file removal skip it, whatever the user clicks. (Shield's side of "Works with
// Pax" is ShieldCore.PaxCompatibility.)
import Foundation

public enum PaxProtection {
    public static let appBundleIDs: Set<String> = ["org.paxmobile.pax", "org.paxpeace.pax"]
    public static let bundleIDPrefixes = ["org.paxmobile.", "org.paxpeace.", "com.paxpeace."]
    public static let teamID = "Z94GSK7JA8"
    public static let guardDirectory = "/Library/PaxGuard"
    public static let appNames: Set<String> = ["pax.app", "pax peace.app"]
    public static let processNames: Set<String> = ["pax-guard", "paxguard", "pax", "pax peace"]

    /// Shown wherever Swoop leaves something of Pax's alone.
    public static let note = "Part of Pax, your accountability blocker. Swoop never removes, disables or flags it."

    public static func isPaxBundleID(_ id: String?) -> Bool {
        guard let id = id?.lowercased(), !id.isEmpty else { return false }
        return appBundleIDs.contains(id) || bundleIDPrefixes.contains { id.hasPrefix($0) }
    }

    public static func isPaxTeamID(_ team: String?) -> Bool { team?.uppercased() == teamID }

    public static func isPaxLaunchdLabel(_ label: String?) -> Bool {
        guard let l = label?.lowercased(), !l.isEmpty else { return false }
        return isPaxBundleID(l) || l.contains("pax-guard") || l.contains("paxguard")
    }

    /// Any path that belongs to Pax: /Library/PaxGuard, pax-guard's launchd plists, the Pax app,
    /// and files or containers named after Pax's bundle IDs.
    public static func isProtectedPath(_ rawPath: String) -> Bool {
        let path = PathSafety.normalize(rawPath).lowercased()
        let guardDir = guardDirectory.lowercased()
        if path == guardDir || path.hasPrefix(guardDir + "/") { return true }
        for comp in path.split(separator: "/").map(String.init) {
            if comp.contains("pax-guard") || comp.contains("paxguard") { return true }
            if bundleIDPrefixes.contains(where: { comp.hasPrefix($0) || comp.contains("." + $0) }) { return true }
        }
        // The app itself, in /Applications or ~/Applications (optionally one folder down).
        if let last = path.split(separator: "/").last.map(String.init), appNames.contains(last),
           path.hasPrefix("/applications/") || path.contains("/applications/") {
            return true
        }
        return false
    }

    /// An app Swoop must not uninstall, quit or force quit.
    public static func isProtectedApp(bundleID: String?, teamID: String? = nil, path: String? = nil) -> Bool {
        if isPaxBundleID(bundleID) || isPaxTeamID(teamID) { return true }
        if let p = path, isProtectedPath(p) { return true }
        return false
    }

    /// A launch agent / daemon Swoop must not disable, remove or flag.
    public static func isProtectedLaunchItem(label: String?, path: String?, program: String?) -> Bool {
        if isPaxLaunchdLabel(label) { return true }
        if let p = path, isProtectedPath(p) { return true }
        if let p = program, p.hasPrefix("/"), isProtectedPath(p) { return true }
        return false
    }

    /// A process Swoop must not quit or kill.
    public static func isProtectedProcess(name: String?, bundleID: String?, path: String? = nil) -> Bool {
        if isPaxBundleID(bundleID) { return true }
        if let n = name?.lowercased(), processNames.contains(n) { return true }
        if let p = path, isProtectedPath(p) { return true }
        return false
    }

    /// A configuration profile Swoop must not offer to remove.
    public static func isProtectedProfile(identifier: String?, organization: String?) -> Bool {
        if isPaxBundleID(identifier) || isPaxLaunchdLabel(identifier) { return true }
        guard let o = organization?.lowercased() else { return false }
        return o == "pax" || o.hasPrefix("pax peace") || o.hasPrefix("pax technologies") || o.contains("paxpeace")
    }
}
