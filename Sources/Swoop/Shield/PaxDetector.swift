// SPDX-License-Identifier: MIT
//
// Gathers the signals ShieldCore.PaxCompatibility decides on: is Pax (paxpeace.com, an
// accountability / adult-content blocker) on this Mac? Read-only: it looks at files, the
// running processes, the system resolver and installed profiles, and changes nothing.
import AppKit
import Foundation
import ShieldCore
import SwoopCore
import SystemConfiguration

enum PaxDetector {
    static func scan() -> (PaxSignals, PaxPresence) {
        var s = PaxSignals()
        let fm = FileManager.default
        let guardDir = fm.fileExists(atPath: PaxCompatibility.guardDirectory)
        s.guardDirectory = guardDir
        let daemons = (try? fm.contentsOfDirectory(atPath: "/Library/LaunchDaemons")) ?? []
        let plist = daemons.contains { PaxCompatibility.isPaxLaunchdLabel(($0 as NSString).deletingPathExtension) }
        let running = processRunning(PaxCompatibility.guardProcessName)
        s.guardLaunchdJob = plist || running
        s.paxApp = paxAppInstalled()
        s.localDNSOwnedByPaxGuard = PaxCompatibility.isLocalDNSOwnedByPaxGuard(
            dnsServers: systemDNSServers(), paxGuardRunning: running, paxGuardInstalled: guardDir || plist)
        s.paxProfile = paxProfileInstalled()
        return (s, PaxCompatibility.evaluate(s))
    }

    static func processRunning(_ name: String) -> Bool {
        Shell.run("/usr/bin/pgrep", ["-x", name]) == 0
    }

    static func paxAppInstalled() -> Bool {
        for id in PaxCompatibility.appBundleIDs where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            return true
        }
        // Renamed copies: any app whose name starts with "Pax" signed by Pax's Team ID.
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.lowercased().hasPrefix("pax") && name.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(name)
                if PaxGuardrails.isPaxApp(path: path, bundleID: Bundle(path: path)?.bundleIdentifier) { return true }
            }
        }
        return false
    }

    /// The resolvers macOS is using right now (State:/Network/Global/DNS).
    static func systemDNSServers() -> [String] {
        guard let v = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any] else { return [] }
        return v["ServerAddresses"] as? [String] ?? []
    }

    /// Pax's device profile: `profiles` output (when readable) or the managed browser policies
    /// it installs, which mention Pax's own DNS / extension.
    static func paxProfileInstalled() -> Bool {
        let markers = ["org.paxmobile.", "org.paxpeace.", "com.paxpeace.", "paxpeace.com", "pax peace"]
        for args in [["list"], ["show", "-type", "configuration"]] {
            if let out = Shell.output("/usr/bin/profiles", args, timeout: 10)?.lowercased(), markers.contains(where: { out.contains($0) }) {
                return true
            }
        }
        let managed = "/Library/Managed Preferences"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: managed)) ?? [] where name.hasSuffix(".plist") {
            guard let d = FileManager.default.contents(atPath: (managed as NSString).appendingPathComponent(name)), d.count < 4_000_000 else { continue }
            let text = (String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)).lowercased()
            if markers.contains(where: { text.contains($0) }) { return true }
        }
        return false
    }
}
