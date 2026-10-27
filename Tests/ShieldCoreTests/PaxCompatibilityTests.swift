// SPDX-License-Identifier: MIT
import XCTest
@testable import ShieldCore

final class PaxCompatibilityTests: XCTestCase {
    func testNoSignalsMeansAbsent() {
        let p = PaxCompatibility.evaluate(PaxSignals())
        XCTAssertFalse(p.detected)
        XCTAssertTrue(p.reasons.isEmpty)
    }

    func testAnySingleSignalMeansPresent() {
        let each: [PaxSignals] = [
            PaxSignals(guardDirectory: true), PaxSignals(guardLaunchdJob: true), PaxSignals(paxApp: true),
            PaxSignals(localDNSOwnedByPaxGuard: true), PaxSignals(paxProfile: true),
        ]
        for s in each {
            let p = PaxCompatibility.evaluate(s)
            XCTAssertTrue(p.detected, "\(s)")
            XCTAssertEqual(p.reasons.count, 1)
        }
        let all = PaxCompatibility.evaluate(PaxSignals(guardDirectory: true, guardLaunchdJob: true, paxApp: true,
                                                       localDNSOwnedByPaxGuard: true, paxProfile: true))
        XCTAssertEqual(all.reasons.count, 5)
    }

    func testLocalDNSOwnership() {
        XCTAssertTrue(PaxCompatibility.isLocalDNSOwnedByPaxGuard(dnsServers: ["127.0.0.1"], paxGuardRunning: true, paxGuardInstalled: false))
        XCTAssertTrue(PaxCompatibility.isLocalDNSOwnedByPaxGuard(dnsServers: ["::1", "192.168.1.1"], paxGuardRunning: false, paxGuardInstalled: true))
        XCTAssertFalse(PaxCompatibility.isLocalDNSOwnedByPaxGuard(dnsServers: ["127.0.0.1"], paxGuardRunning: false, paxGuardInstalled: false),
                       "loopback DNS without pax-guard is someone else's resolver (e.g. Swoop's own)")
        XCTAssertFalse(PaxCompatibility.isLocalDNSOwnedByPaxGuard(dnsServers: ["1.1.1.1"], paxGuardRunning: true, paxGuardInstalled: true))
        XCTAssertFalse(PaxCompatibility.isLocalDNSOwnedByPaxGuard(dnsServers: [], paxGuardRunning: true, paxGuardInstalled: true))
    }

    func testIdentifiers() {
        XCTAssertTrue(PaxCompatibility.isPaxBundleID("org.paxmobile.pax"))
        XCTAssertTrue(PaxCompatibility.isPaxBundleID("org.paxpeace.pax"))
        XCTAssertTrue(PaxCompatibility.isPaxBundleID("ORG.PAXMOBILE.PAX.helper"))
        XCTAssertFalse(PaxCompatibility.isPaxBundleID("com.example.paxton"))
        XCTAssertFalse(PaxCompatibility.isPaxBundleID(nil))
        XCTAssertTrue(PaxCompatibility.isPaxTeamID("Z94GSK7JA8"))
        XCTAssertFalse(PaxCompatibility.isPaxTeamID("ABCDE12345"))
        XCTAssertTrue(PaxCompatibility.isPaxLaunchdLabel("org.paxmobile.pax-guard"))
        XCTAssertTrue(PaxCompatibility.isPaxLaunchdLabel("com.example.pax-guard"))
        XCTAssertFalse(PaxCompatibility.isPaxLaunchdLabel("com.swoopkey.swoop.resolver"))
        XCTAssertTrue(PaxCompatibility.isPaxProfile(identifier: "org.paxmobile.pax.profile", organization: nil))
        XCTAssertTrue(PaxCompatibility.isPaxProfile(identifier: "x", organization: "Pax Peace"))
        XCTAssertFalse(PaxCompatibility.isPaxProfile(identifier: "com.swoopkey.swoop.shield.dns", organization: "Swoop"))
    }

    func testLayersAllowedNextToPax() {
        for l in ShieldLayer.allCases { XCTAssertTrue(PaxCompatibility.permits(l, paxPresent: false), l.rawValue) }
        let allowed: Set<ShieldLayer> = [.safariContentBlockers, .browserExtension, .contentFilterDropOnly]
        for l in ShieldLayer.allCases {
            XCTAssertEqual(PaxCompatibility.permits(l, paxPresent: true), allowed.contains(l), l.rawValue)
        }
    }

    func testProtectedHostsAndIPs() {
        for h in ["dns.paxpeace.com", "api.paxpeace.com", "paxpeace.com", "doh.cleanbrowsing.org", "family-filter-dns.cleanbrowsing.org",
                  "family.adguard-dns.com", "dns-family.adguard.com", "DNS.PAXPEACE.COM."] {
            XCTAssertTrue(PaxCompatibility.isProtectedHost(h), h)
        }
        for h in ["paxpeace.com.evil.net", "notpaxpeace.com", "dns.google", "ads.example.com"] {
            XCTAssertFalse(PaxCompatibility.isProtectedHost(h), h)
        }
        XCTAssertTrue(PaxCompatibility.isProtectedIP("185.228.168.168"))
        XCTAssertTrue(PaxCompatibility.isProtectedIP("94.140.14.15"))
        XCTAssertFalse(PaxCompatibility.isProtectedIP("8.8.8.8"))
        XCTAssertFalse(PaxCompatibility.isProtectedIP(nil))
    }

    func testEngineInPaxModeNeverBlocksPaxAndSkipsBypassBlocking() throws {
        let idx = try makeIndex([("l", "||ads.example.com^\n||paxpeace.com^\n||cleanbrowsing.org^")])
        var cfg = ShieldConfig()
        let normal = ShieldEngine(config: cfg, index: idx)
        XCTAssertEqual(normal.decide(name: "dns.google").action, .blocked, "bypass blocking on without Pax")
        XCTAssertEqual(normal.decide(name: "dns.paxpeace.com").action, .blocked)
        if case .allow = normal.flowVerdict(remoteIP: "1.1.1.1", remoteHostname: nil, port: 853, proto: .tcp, app: nil) { XCTFail("DoT should drop without Pax") }

        cfg.paxCompatible = true
        let pax = ShieldEngine(config: cfg, index: idx)
        XCTAssertNotEqual(pax.decide(name: "dns.paxpeace.com").action, .blocked)
        XCTAssertNotEqual(pax.decide(name: "doh.cleanbrowsing.org").action, .blocked)
        XCTAssertNotEqual(pax.decide(name: "dns.google").action, .blocked, "no DoH-bypass blocking next to Pax")
        XCTAssertNotEqual(pax.decide(name: "use-application-dns.net").action, .blocked)
        XCTAssertEqual(pax.decide(name: "ads.example.com").action, .blocked, "ads are still blocked")
        // Content filter: drop-only, never Pax's resolvers, no bypass drops.
        XCTAssertEqual(pax.flowVerdict(remoteIP: "185.228.168.168", remoteHostname: nil, port: 853, proto: .tcp, app: nil), .allow)
        XCTAssertEqual(pax.flowVerdict(remoteIP: "203.0.113.5", remoteHostname: "dns.paxpeace.com", port: 443, proto: .tcp, app: nil), .allow)
        XCTAssertEqual(pax.flowVerdict(remoteIP: "1.1.1.1", remoteHostname: nil, port: 853, proto: .tcp, app: nil), .allow)
        if case .allow = pax.flowVerdict(remoteIP: "203.0.113.9", remoteHostname: "ads.example.com", port: 443, proto: .tcp, app: nil) {
            XCTFail("blocked ad hosts are still dropped")
        }
    }

    func testConfigRoundTripAndOldConfigs() throws {
        var c = ShieldConfig()
        c.paxCompatible = true
        c.paxContentFilter = true
        let back = try XCTUnwrap(ShieldConfig.decode(c.encoded()))
        XCTAssertTrue(back.paxCompatible)
        XCTAssertTrue(back.paxContentFilter)
        let old = try XCTUnwrap(ShieldConfig.decode(Data(#"{"enabled":true}"#.utf8)))
        XCTAssertFalse(old.paxCompatible)
        XCTAssertFalse(old.paxContentFilter)
    }

    func testBuiltInBrowserRulesNeverBlockPax() throws {
        let c = try ShieldCompiler.compile([ListText(source: ShieldCompiler.builtInSource, text: "||paxpeace.com^")])
        let dnr = try XCTUnwrap(c.dnr)
        let rules = dnr.rulesets.flatMap { $0.rules }
        let allow = rules.first { $0.action.type == "allow" && ($0.condition.requestDomains ?? []).contains("paxpeace.com") }
        let block = rules.first { $0.action.type == "block" && ($0.condition.requestDomains ?? []).contains("paxpeace.com") }
        let a = try XCTUnwrap(allow, "built-in rules allow paxpeace.com")
        if let b = block { XCTAssertGreaterThan(a.priority, b.priority) }
    }
}
