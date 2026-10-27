// SPDX-License-Identifier: MIT
//
// "Works with Pax": Pax (paxpeace.com) is an accountability / adult-content blocker for the
// Mac. Its root daemon pax-guard owns the Mac's DNS (a forwarder on 127.0.0.1:53 that the
// network settings point at), adds /etc/hosts blocks and pf rules, installs a locked
// configuration profile, and treats DNS changes, VPN-like and DNS-proxy network extensions
// as tampering. Swoop must never fight it. When Pax is present Shield:
//   • never installs or enables its DNS proxy, local resolver (port 53) or encrypted-DNS
//     profile, and never touches network DNS settings, /etc/hosts or pf;
//   • never blocks Pax's own servers or the filtering resolvers Pax falls back to, and turns
//     its own DNS-bypass blocking off;
//   • blocks ads in the browsers (Safari content blockers + web extension) and, optionally,
//     with the content filter, which can only ever drop connections (it can't allow or
//     redirect anything Pax blocks).
// The decision logic lives here (Foundation only, unit-tested); Swoop.app gathers the signals.
import Foundation

/// What Swoop.app found on this Mac. Any one signal means Pax is present.
public struct PaxSignals: Codable, Equatable {
    /// /Library/PaxGuard exists.
    public var guardDirectory = false
    /// A launchd job for pax-guard (plist in /Library/LaunchDaemons, or the job is loaded / running).
    public var guardLaunchdJob = false
    /// The Pax app (org.paxmobile.pax / org.paxpeace.pax, or signed by Pax's Team ID).
    public var paxApp = false
    /// The system resolver is 127.0.0.1 / ::1 and that forwarder belongs to pax-guard.
    public var localDNSOwnedByPaxGuard = false
    /// Pax's device configuration profile is installed.
    public var paxProfile = false

    public init(guardDirectory: Bool = false, guardLaunchdJob: Bool = false, paxApp: Bool = false,
                localDNSOwnedByPaxGuard: Bool = false, paxProfile: Bool = false) {
        self.guardDirectory = guardDirectory
        self.guardLaunchdJob = guardLaunchdJob
        self.paxApp = paxApp
        self.localDNSOwnedByPaxGuard = localDNSOwnedByPaxGuard
        self.paxProfile = paxProfile
    }
}

public struct PaxPresence: Equatable {
    public var detected: Bool
    /// Plain-English list of what was found (shown in Shield › Works with Pax).
    public var reasons: [String]

    public static let absent = PaxPresence(detected: false, reasons: [])
}

/// The ways Shield can filter. Used to decide what is allowed next to Pax.
public enum ShieldLayer: String, CaseIterable {
    case dnsProxy                    // NEDNSProxyProvider system extension
    case localResolver               // swoop-resolver LaunchDaemon on 127.0.0.1:53
    case encryptedDNSProfile         // DNS-settings configuration profile
    case networkDNSSettings          // networksetup -setdnsservers
    case hostsFile                   // /etc/hosts
    case packetFilter                // pf
    case encryptedDNSBypassBlocking  // dropping DoH/DoT/DoQ to public resolvers
    case contentFilterDropOnly       // NEFilterDataProvider that only ever drops flows
    case safariContentBlockers
    case browserExtension
}

public enum PaxCompatibility {
    public static let guardDirectory = "/Library/PaxGuard"
    public static let appBundleIDs: Set<String> = ["org.paxmobile.pax", "org.paxpeace.pax"]
    public static let bundleIDPrefixes = ["org.paxmobile.", "org.paxpeace.", "com.paxpeace."]
    public static let teamID = "Z94GSK7JA8"
    public static let guardProcessName = "pax-guard"

    // MARK: detection

    public static func evaluate(_ s: PaxSignals) -> PaxPresence {
        var reasons: [String] = []
        if s.guardDirectory { reasons.append("Pax's protection service is installed (\(guardDirectory)).") }
        if s.guardLaunchdJob { reasons.append("Pax's background service (pax-guard) is set up to run.") }
        if s.paxApp { reasons.append("The Pax app is installed.") }
        if s.localDNSOwnedByPaxGuard { reasons.append("Your Mac's DNS goes through Pax's filter on 127.0.0.1.") }
        if s.paxProfile { reasons.append("Pax's device profile is installed.") }
        return PaxPresence(detected: !reasons.isEmpty, reasons: reasons)
    }

    /// System DNS is a loopback forwarder and pax-guard is the one providing it.
    public static func isLocalDNSOwnedByPaxGuard(dnsServers: [String], paxGuardRunning: Bool, paxGuardInstalled: Bool) -> Bool {
        let loopback = dnsServers.contains { s in
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            return t == "::1" || t.hasPrefix("127.")
        }
        return loopback && (paxGuardRunning || paxGuardInstalled)
    }

    public static func isPaxBundleID(_ id: String?) -> Bool {
        guard let id = id?.lowercased(), !id.isEmpty else { return false }
        return appBundleIDs.contains(id) || bundleIDPrefixes.contains { id.hasPrefix($0) }
    }

    public static func isPaxTeamID(_ team: String?) -> Bool { team?.uppercased() == teamID }

    /// launchd labels and plist names that belong to Pax.
    public static func isPaxLaunchdLabel(_ label: String?) -> Bool {
        guard let l = label?.lowercased(), !l.isEmpty else { return false }
        return isPaxBundleID(l) || l.contains("pax-guard") || l.contains("paxguard")
    }

    /// Configuration profiles (identifier or organisation) that belong to Pax.
    public static func isPaxProfile(identifier: String?, organization: String?) -> Bool {
        if isPaxBundleID(identifier) || isPaxLaunchdLabel(identifier) { return true }
        guard let o = organization?.lowercased() else { return false }
        return o == "pax" || o.hasPrefix("pax peace") || o.hasPrefix("pax technologies") || o.contains("paxpeace")
    }

    // MARK: what Shield may do

    /// Whether a Shield layer may run. Without Pax everything is allowed; with Pax only the
    /// browser layers and a drop-only content filter are.
    public static func permits(_ layer: ShieldLayer, paxPresent: Bool) -> Bool {
        guard paxPresent else { return true }
        switch layer {
        case .safariContentBlockers, .browserExtension, .contentFilterDropOnly: return true
        case .dnsProxy, .localResolver, .encryptedDNSProfile, .networkDNSSettings, .hostsFile, .packetFilter,
             .encryptedDNSBypassBlocking:
            return false
        }
    }

    // MARK: hosts Shield never blocks next to Pax

    /// Pax's servers and the filtering / malware resolvers it uses or falls back to
    /// (subdomains included).
    public static let protectedDomains: [String] = [
        "paxpeace.com",                                   // dns.paxpeace.com (DoH), api.paxpeace.com, website
        "cleanbrowsing.org",                              // CleanBrowsing family / adult filters (DoH + DoT)
        "family.adguard-dns.com", "dns-family.adguard.com", // AdGuard Family
        "dns.quad9.net", "security.cloudflare-dns.com",   // malware-only upstreams
    ]

    public static let protectedIPs: Set<String> = Set([
        // CleanBrowsing (security, adult, family)
        "185.228.168.9", "185.228.169.9", "185.228.168.10", "185.228.169.11", "185.228.168.168", "185.228.169.168",
        "2a0d:2a00:1::", "2a0d:2a00:2::", "2a0d:2a00:1::1", "2a0d:2a00:2::1", "2a0d:2a00:1::2", "2a0d:2a00:2::2",
        // AdGuard Family
        "94.140.14.15", "94.140.15.16", "2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff",
        // Quad9, Cloudflare malware blocking
        "9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9", "1.1.1.2", "1.0.0.2",
        "2606:4700:4700::1112", "2606:4700:4700::1002",
    ].compactMap { IPAddress.parse($0)?.description })

    public static func isProtectedHost(_ name: String?) -> Bool {
        guard let n = name.flatMap({ DomainName.normalize($0) }) else { return false }
        return protectedDomains.contains { DomainName.isSubdomain(n, of: $0) }
    }

    public static func isProtectedIP(_ ip: String?) -> Bool {
        guard let a = ip.flatMap({ IPAddress.parse($0)?.description }) else { return false }
        return protectedIPs.contains(a)
    }
}
