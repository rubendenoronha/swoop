// SPDX-License-Identifier: MIT
//
// Browsers and some apps send DNS over HTTPS / TLS / QUIC straight to a public resolver,
// which walks around any system-level filter. Shield closes that gap three ways:
//   1. Canary and resolver names: `use-application-dns.net` gets NXDOMAIN (Firefox then turns
//      its automatic DoH off), and well-known DoH hostnames don't resolve, so browsers fall
//      back to the system resolver, which Shield filters. Chrome/Edge/Brave only "upgrade"
//      to DoH when the system resolver is itself a known DoH provider, which Shield isn't.
//   2. iCloud Private Relay's documented network opt-out names (mask.icloud.com,
//      mask-h2.icloud.com) are optionally answered NXDOMAIN so Safari's DNS stays filtered.
//   3. The content filter (system extension mode) drops flows to known resolver IPs on
//      443/853 and DNS-over-TLS / DNS-over-QUIC (port 853) to anyone but Shield's upstream.
import Foundation

public enum EncryptedDNSMode: String, Codable, CaseIterable {
    /// Push browsers/apps back to the system resolver (recommended).
    case blockBypass
    /// Leave encrypted DNS alone (apps using their own DoH aren't filtered).
    case allow

    public var title: String {
        switch self {
        case .blockBypass: return "Route encrypted DNS through Shield"
        case .allow: return "Leave apps' own encrypted DNS alone"
        }
    }
}

public enum FlowProtocol: String, Codable { case tcp, udp }

public enum FlowVerdict: Equatable {
    case allow
    case drop(reason: String)
}

public struct EncryptedDNSPolicy {
    public var mode: EncryptedDNSMode
    public var blockPrivateRelay: Bool
    /// Shield's own upstream (never blocked): hostnames and IPs.
    public var upstreamHosts: Set<String>
    public var upstreamIPs: Set<String>

    public init(mode: EncryptedDNSMode = .blockBypass, blockPrivateRelay: Bool = false,
                upstreamHosts: Set<String> = [], upstreamIPs: Set<String> = []) {
        self.mode = mode
        self.blockPrivateRelay = blockPrivateRelay
        self.upstreamHosts = upstreamHosts
        self.upstreamIPs = Set(upstreamIPs.compactMap { IPAddress.parse($0)?.description })
    }

    /// Names that tell Firefox not to enable DoH on this network.
    public static let canaryDomains = ["use-application-dns.net"]
    /// Apple's documented Private Relay network opt-out names.
    public static let privateRelayDomains = ["mask.icloud.com", "mask-h2.icloud.com"]

    /// Public DoH/DoT endpoints (subdomains included). Not exhaustive; the filter's port-853
    /// rule and the "Encrypted DNS" category of HaGeZi's lists cover more.
    public static let resolverHostnames: [String] = [
        "dns.google", "dns.google.com", "8888.google", "cloudflare-dns.com", "one.one.one.one", "1dot1dot1dot1.cloudflare-dns.com",
        "chrome.cloudflare-dns.com", "mozilla.cloudflare-dns.com", "security.cloudflare-dns.com", "family.cloudflare-dns.com",
        "dns.quad9.net", "dns9.quad9.net", "dns10.quad9.net", "dns11.quad9.net", "doh.opendns.com", "doh.familyshield.opendns.com",
        "dns.nextdns.io", "chromium.dns.nextdns.io", "firefox.dns.nextdns.io", "dns.adguard-dns.com", "dns.adguard.com",
        "dns-family.adguard.com", "unfiltered.adguard-dns.com", "family.adguard-dns.com", "doh.cleanbrowsing.org",
        "dns.mullvad.net", "adblock.dns.mullvad.net", "base.dns.mullvad.net", "extended.dns.mullvad.net", "all.dns.mullvad.net",
        "doh.mullvad.net", "doh.dns.sb", "dns.twnic.tw", "doh.libredns.gr", "dns.controld.com", "freedns.controld.com",
        "doh.xfinity.com", "dns.comcast.net", "doh-01.spectrum.com", "doh-02.spectrum.com", "dns.alidns.com", "doh.pub",
        "dns.pub", "doh.360.cn", "dns.switch.ch", "dns.digitale-gesellschaft.ch", "doh.ffmuc.net", "dns.njal.la",
        "doh.applied-privacy.net", "dns0.eu", "zero.dns0.eu", "kids.dns0.eu", "open.dns0.eu", "dns.decloudus.com",
        "doh.tiar.app", "doh.crypto.sx", "odvr.nic.cz", "dns.rabbitdns.org", "public.dns.iij.jp", "dns.quad101.com",
        "ordns.he.net", "dns.brahma.world", "dns.surfsharkdns.com", "dns.bebasid.com", "dns.levonet.sk", "doh.opendns.com",
        "resolver2.dns.watch", "doh.safesurfer.io", "dns.umbrella.com", "dns.alekberg.net", "wikimedia-dns.org",
        "dns.startupstash.com", "doh.seby.io", "dns.east.comss.one", "dns.comss.one", "dns.yandex.ru", "common.dot.dns.yandex.net",
    ]

    /// Anycast addresses of the big public resolvers. A connection to these on 443 or 853 is
    /// almost certainly encrypted DNS.
    public static let resolverIPs: Set<String> = Set([
        "8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844",
        "1.1.1.1", "1.0.0.1", "1.1.1.2", "1.0.0.2", "1.1.1.3", "1.0.0.3",
        "2606:4700:4700::1111", "2606:4700:4700::1001", "2606:4700:4700::1112", "2606:4700:4700::1002",
        "2606:4700:4700::1113", "2606:4700:4700::1003", "104.16.248.249", "104.16.249.249",
        "9.9.9.9", "149.112.112.112", "9.9.9.10", "149.112.112.10", "9.9.9.11", "149.112.112.11",
        "2620:fe::fe", "2620:fe::9", "2620:fe::10", "2620:fe::11",
        "208.67.222.222", "208.67.220.220", "208.67.222.123", "208.67.220.123", "2620:119:35::35", "2620:119:53::53",
        "94.140.14.14", "94.140.15.15", "94.140.14.15", "94.140.15.16", "94.140.14.140", "94.140.14.141",
        "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff", "185.228.168.168", "185.228.169.168", "185.228.168.9", "185.228.169.9",
        "194.242.2.2", "194.242.2.3", "194.242.2.4", "194.242.2.5", "194.242.2.6", "194.242.2.9",
        "76.76.2.0", "76.76.10.0", "76.76.2.2", "76.76.2.11", "45.90.28.0", "45.90.30.0",
        "185.222.222.222", "45.11.45.11", "193.110.81.0", "185.253.5.0", "223.5.5.5", "223.6.6.6", "1.12.12.12", "120.53.53.53",
    ].compactMap { IPAddress.parse($0)?.description })

    /// For a DNS query: should Shield answer NXDOMAIN to defeat a bypass?
    public func queryVerdict(_ name: String) -> MatchResult {
        guard mode == .blockBypass, let n = DomainName.normalize(name) else { return .noMatch }
        if upstreamHosts.contains(where: { DomainName.isSubdomain(n, of: $0) }) { return .noMatch }
        if EncryptedDNSPolicy.canaryDomains.contains(where: { DomainName.isSubdomain(n, of: $0) }) {
            return .blocked(MatchInfo(source: "doh-policy", rule: "||use-application-dns.net^ (Firefox DoH canary)"))
        }
        if blockPrivateRelay, EncryptedDNSPolicy.privateRelayDomains.contains(n) {
            return .blocked(MatchInfo(source: "doh-policy", rule: "||\(n)^ (iCloud Private Relay opt-out)"))
        }
        if let hit = EncryptedDNSPolicy.resolverHostnames.first(where: { DomainName.isSubdomain(n, of: $0) }) {
            return .blocked(MatchInfo(source: "doh-policy", rule: "||\(hit)^ (encrypted DNS resolver)"))
        }
        return .noMatch
    }

    /// For a network flow seen by the content filter.
    public func flowVerdict(remoteIP: String?, remoteHostname: String?, port: Int, proto: FlowProtocol) -> FlowVerdict {
        guard mode == .blockBypass else { return .allow }
        let ip = remoteIP.flatMap { IPAddress.parse($0)?.description }
        if let ip = ip, upstreamIPs.contains(ip) { return .allow }
        if let h = remoteHostname.flatMap({ DomainName.normalize($0) }),
           upstreamHosts.contains(where: { DomainName.isSubdomain(h, of: $0) }) { return .allow }
        if port == 853 { return .drop(reason: proto == .tcp ? "DNS-over-TLS bypass" : "DNS-over-QUIC bypass") }
        if port == 443 || port == 8443 {
            if let ip = ip, EncryptedDNSPolicy.resolverIPs.contains(ip) {
                return .drop(reason: proto == .tcp ? "DNS-over-HTTPS to \(ip)" : "DNS-over-HTTP/3 to \(ip)")
            }
            if let h = remoteHostname.flatMap({ DomainName.normalize($0) }),
               let hit = EncryptedDNSPolicy.resolverHostnames.first(where: { DomainName.isSubdomain(h, of: $0) }) {
                return .drop(reason: "DNS-over-HTTPS to \(hit)")
            }
        }
        return .allow
    }
}
