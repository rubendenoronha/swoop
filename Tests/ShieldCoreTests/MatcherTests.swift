// SPDX-License-Identifier: MIT
import XCTest
@testable import ShieldCore

func makeIndex(_ lists: [(String, String)], options: RuleParserOptions = .dnsList) throws -> ShieldIndex {
    var b = DomainIndexBuilder()
    for (src, text) in lists {
        let si = try b.source(src)
        for line in text.components(separatedBy: "\n") {
            if let h = RuleParser.hostsEntries(line), !h.isEmpty { h.forEach { b.add($0, sourceIndex: si) }; continue }
            let r = RuleParser.parseLine(line, options: options)
            if let d = r.dns { b.add(d, sourceIndex: si) }
            if let bf = r.badfilterDNS { b.disable(bf) }
        }
    }
    return try ShieldIndex(data: b.build())
}

final class DomainIndexTests: XCTestCase {
    func testSubtreeExactAndAttribution() throws {
        let idx = try makeIndex([("listA", "||doubleclick.net^\n0.0.0.0 exact.tracker.com"), ("listB", "@@||safe.doubleclick.net^")])
        XCTAssertTrue(idx.lookup("doubleclick.net").flags.blocks)
        let deep = idx.lookup("a.b.c.doubleclick.net")
        XCTAssertTrue(deep.flags.blocks)
        XCTAssertEqual(deep.blockSource, "listA")
        XCTAssertEqual(deep.blockedBy, "doubleclick.net")
        XCTAssertTrue(idx.lookup("exact.tracker.com").flags.blocks)
        XCTAssertFalse(idx.lookup("sub.exact.tracker.com").flags.blocks, "hosts entries block that exact name only")
        let safe = idx.lookup("x.safe.doubleclick.net")
        XCTAssertTrue(safe.flags.allows)
        XCTAssertEqual(safe.allowSource, "listB")
        XCTAssertTrue(idx.lookup("notdoubleclick.net").isEmpty)
        XCTAssertTrue(idx.lookup("net").isEmpty)
    }

    func testRoundTripAndHeader() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        var b = DomainIndexBuilder()
        try b.add(DNSRule(pattern: HostPattern(.subtree, "a.com")), source: "s")
        let data = b.build(createdAt: when)
        let idx = try ShieldIndex(data: data)
        XCTAssertEqual(idx.createdAt, when)
        XCTAssertEqual(idx.sources, ["s"])
        XCTAssertEqual(idx.domainCount, 1)
    }

    func testTamperAndGarbageAreRejected() throws {
        var b = DomainIndexBuilder()
        try b.add(DNSRule(pattern: HostPattern(.subtree, "ads.example.com")), source: "s")
        var data = b.build()
        data[data.count / 2] ^= 0xFF
        XCTAssertThrowsError(try ShieldIndex(data: data)) { XCTAssertEqual($0 as? DomainIndexError, .checksumMismatch) }
        XCTAssertThrowsError(try ShieldIndex(data: Data(repeating: 7, count: 200))) { XCTAssertEqual($0 as? DomainIndexError, .badMagic) }
        XCTAssertThrowsError(try ShieldIndex(data: Data([1, 2, 3])))
    }

    func testBadfilterDisablesRule() throws {
        let idx = try makeIndex([("a", "||ads.example.com^\n||keep.example.com^"), ("b", "||ads.example.com^$badfilter")])
        XCTAssertFalse(idx.lookup("ads.example.com").flags.blocks)
        XCTAssertTrue(idx.lookup("keep.example.com").flags.blocks)
    }

    func testMatchesNaiveSetOnRandomData() throws {
        var rng = SystemRandomNumberGenerator()
        let tlds = ["com", "net", "org", "io", "co.uk"]
        var listed: Set<String> = []
        var text = ""
        for i in 0..<3000 {
            let d = "d\(i)-\(UInt16.random(in: 0...999, using: &rng)).\(tlds[i % tlds.count])"
            listed.insert(d)
            text += "||\(d)^\n"
        }
        let idx = try makeIndex([("r", text)])
        for d in listed.prefix(500) {
            XCTAssertTrue(idx.lookup(d).flags.blocks, d)
            XCTAssertTrue(idx.lookup("x.y." + d).flags.blocks, d)
            XCTAssertFalse(idx.lookup("z" + d).flags.blocks && !listed.contains("z" + d), d)
        }
    }

    func testComplexRules() throws {
        let idx = try makeIndex([("w", "||ad*.example.com^\n/^track[0-9]+\\.example\\.org$/\n||cdn.example.net^$denyallow=good.example.net\n||v6only.example^$dnstype=AAAA")])
        XCTAssertFalse(idx.complexMatches("ad1.example.com", type: nil).isEmpty)
        XCTAssertFalse(idx.complexMatches("x.ad1.example.com", type: nil).isEmpty, "glob rules cover subdomains of a match")
        XCTAssertTrue(idx.complexMatches("bad1.example.com", type: nil).isEmpty)
        XCTAssertFalse(idx.complexMatches("track42.example.org", type: nil).isEmpty)
        XCTAssertTrue(idx.complexMatches("track.example.org", type: nil).isEmpty)
        XCTAssertFalse(idx.complexMatches("img.cdn.example.net", type: nil).isEmpty)
        XCTAssertTrue(idx.complexMatches("good.example.net", type: nil).isEmpty)
        XCTAssertFalse(idx.complexMatches("v6only.example", type: "AAAA").isEmpty)
        XCTAssertTrue(idx.complexMatches("v6only.example", type: "A").isEmpty)
    }
}

final class DomainMatcherTests: XCTestCase {
    func testPrecedence() throws {
        let idx = try makeIndex([
            ("lists", """
            ||tracker.com^
            @@||ok.tracker.com^
            ||forced.tracker.com^$important
            @@||vip.forced.tracker.com^$important
            ||ads.example.org^
            """),
        ])
        let m = DomainMatcher(lists: idx, user: UserRules(allowlist: ["https://mine.tracker.com/page"],
                                                          customRules: "||ads.example.org^\n@@||ok.ads.example.org^\n||myblock.com^\n0.0.0.0 hostsblock.com"))
        XCTAssertEqual(m.match("x.tracker.com").info?.source, "lists")
        XCTAssertTrue(m.match("x.tracker.com").isBlocked)
        XCTAssertTrue(m.match("ok.tracker.com").isAllowed, "exception beats block")
        XCTAssertTrue(m.match("a.forced.tracker.com").isBlocked, "$important block beats ordinary exception")
        XCTAssertTrue(m.match("vip.forced.tracker.com").isAllowed, "$important exception beats $important block")
        XCTAssertEqual(m.match("mine.tracker.com").info?.source, "allowlist", "the allowlist always wins")
        XCTAssertEqual(m.match("myblock.com").info?.source, "custom")
        XCTAssertTrue(m.match("hostsblock.com").isBlocked)
        XCTAssertTrue(m.match("ok.ads.example.org").isAllowed)
        XCTAssertEqual(m.match("ok.ads.example.org").info?.source, "custom")
        XCTAssertEqual(m.match("nothing.example"), .noMatch)
        XCTAssertEqual(m.match("not a host"), .noMatch)
    }

    func testWildcardExceptionsAndCustomRegex() throws {
        let idx = try makeIndex([("l", "||adserver.net^\n@@||static*.adserver.net^")])
        let m = DomainMatcher(lists: idx, user: UserRules(customRules: "/^pixel[0-9]+\\.shop\\.com$/"))
        XCTAssertTrue(m.match("x.adserver.net").isBlocked)
        XCTAssertTrue(m.match("static3.adserver.net").isAllowed)
        XCTAssertTrue(m.match("pixel9.shop.com").isBlocked)
        XCTAssertFalse(m.match("www.shop.com").isBlocked)
    }

    func testNoListsStillAppliesUserRules() {
        let m = DomainMatcher(lists: nil, user: UserRules(customRules: "evil.example"))
        XCTAssertTrue(m.match("www.evil.example").isBlocked)
        XCTAssertEqual(m.match("good.example"), .noMatch)
    }
}

final class CNAMETests: XCTestCase {
    let rules = try! makeIndex([("l", "||tracker-network.net^\n@@||cdn-allowed.net^")])

    func testCloakedTrackerIsBlocked() {
        let m = DomainMatcher(lists: rules)
        let u = CNAMEUncloaker()
        let r = u.evaluate(query: "metrics.shop.com", queryResult: m.match("metrics.shop.com"),
                           chain: ["shop.tracker-network.net", "edge.cdn.net"]) { m.match($0) }
        XCTAssertTrue(r.isBlocked)
        if case .blocked(let i) = r.verdict { XCTAssertEqual(i.cnameTarget, "shop.tracker-network.net") }
    }

    func testExplicitAllowOfQueryWins() {
        let m = DomainMatcher(lists: rules, user: UserRules(allowlist: ["metrics.shop.com"]))
        let r = CNAMEUncloaker().evaluate(query: "metrics.shop.com", queryResult: m.match("metrics.shop.com"),
                                          chain: ["shop.tracker-network.net"]) { m.match($0) }
        XCTAssertFalse(r.isBlocked)
    }

    func testAllowedAliasStopsTheWalk() {
        let m = DomainMatcher(lists: rules)
        let r = CNAMEUncloaker().evaluate(query: "img.shop.com", queryResult: .noMatch,
                                          chain: ["a.cdn-allowed.net", "b.tracker-network.net"]) { m.match($0) }
        XCTAssertFalse(r.isBlocked)
    }

    func testLoopAndLengthLimits() {
        let r = CNAMEUncloaker(maxChainLength: 3).evaluate(query: "a.com", queryResult: .noMatch,
                                                           chain: ["b.com", "c.com", "a.com", "d.com"]) { _ in .noMatch }
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.chain, ["b.com", "c.com"])
        let long = CNAMEUncloaker(maxChainLength: 2).evaluate(query: "a.com", queryResult: .noMatch,
                                                              chain: ["b.com", "c.com", "d.com"]) { _ in .noMatch }
        XCTAssertTrue(long.truncated)
        XCTAssertEqual(long.chain.count, 2)
    }

    func testBuiltInTrackersOnlyAcrossSites() {
        let u = CNAMEUncloaker()
        let cross = u.evaluate(query: "f7ds.news.fr", queryResult: .noMatch, chain: ["news.eulerian.net"]) { _ in .noMatch }
        XCTAssertTrue(cross.isBlocked)
        if case .blocked(let i) = cross.verdict { XCTAssertEqual(i.source, "cname") }
        let same = u.evaluate(query: "www.eulerian.net", queryResult: .noMatch, chain: ["edge.eulerian.net"]) { _ in .noMatch }
        XCTAssertFalse(same.isBlocked, "a tracker's own site isn't 'cloaked'")
        let off = CNAMEUncloaker(useBuiltInTrackers: false).evaluate(query: "f7ds.news.fr", queryResult: .noMatch,
                                                                     chain: ["news.eulerian.net"]) { _ in .noMatch }
        XCTAssertFalse(off.isBlocked)
    }

    func testChainFromWireResponse() throws {
        let msg = try DNSMessage.parse(TestDNS.cnameResponse(query: "metrics.shop.com", chain: ["shop.tracker-network.net"], ip: [1, 2, 3, 4]))
        XCTAssertEqual(msg.aliasChain(for: "metrics.shop.com"), ["shop.tracker-network.net"])
        XCTAssertEqual(msg.addresses, ["1.2.3.4"])
        let engine = ShieldEngine(index: rules)
        let d = engine.inspect(response: msg, query: "metrics.shop.com", prior: .pass)
        XCTAssertEqual(d.action, .blocked)
        XCTAssertEqual(d.info?.cnameTarget, "shop.tracker-network.net")
        var cfg = ShieldConfig(); cfg.cnameUncloaking = false
        engine.update(config: cfg)
        XCTAssertEqual(engine.inspect(response: msg, query: "metrics.shop.com", prior: .pass).action, .passed)
    }
}

/// Hand-built DNS wire messages.
enum TestDNS {
    static func name(_ n: String) -> [UInt8] { DNSMessage.encodeName(n) }

    static func cnameResponse(query: String, chain: [String], ip: [UInt8], id: UInt16 = 0x1234) -> Data {
        var out: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x81, 0x80, 0, 1, 0, UInt8(chain.count + 1), 0, 0, 0, 0]
        out += name(query) + [0, 1, 0, 1]
        var owner = query
        for target in chain {
            let rdata = name(target)
            out += name(owner) + [0, 5, 0, 1, 0, 0, 0, 60, 0, UInt8(rdata.count)] + rdata
            owner = target
        }
        out += name(owner) + [0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + ip
        return Data(out)
    }
}

final class DNSMessageTests: XCTestCase {
    func testQueryRoundTrip() throws {
        let q = DNSMessage.makeQuery(id: 77, name: "Ads.Example.com", type: DNSRecordType.aaaa.rawValue, edns: true)
        let m = try DNSMessage.parse(q)
        XCTAssertEqual(m.id, 77)
        XCTAssertEqual(m.questions.first?.name, "ads.example.com")
        XCTAssertEqual(m.questions.first?.typeName, "AAAA")
        XCTAssertTrue(m.hasEDNS)
        XCTAssertFalse(m.isResponse)
    }

    func testBlockedResponses() throws {
        let q = DNSMessage.makeQuery(id: 9, name: "ads.example.com", type: DNSRecordType.a.rawValue, edns: true)
        let nx = try DNSMessage.parse(DNSMessage.blockedResponse(to: q, mode: .nxdomain)!)
        XCTAssertEqual(nx.id, 9)
        XCTAssertTrue(nx.isResponse)
        XCTAssertEqual(nx.rcode, DNSRCode.nxDomain.rawValue)
        XCTAssertTrue(nx.hasEDNS, "EDE option travels in an OPT record")
        let raw = [UInt8](DNSMessage.blockedResponse(to: q, mode: .nxdomain)!)
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("Swoop Shield"))

        let null = try DNSMessage.parse(DNSMessage.blockedResponse(to: q, mode: .nullIP)!)
        XCTAssertEqual(null.rcode, 0)
        XCTAssertEqual(null.addresses, ["0.0.0.0"])
        let q6 = DNSMessage.makeQuery(id: 10, name: "ads.example.com", type: DNSRecordType.aaaa.rawValue)
        XCTAssertEqual(try DNSMessage.parse(DNSMessage.blockedResponse(to: q6, mode: .nullIP)!).addresses, ["::"])
        let qtxt = DNSMessage.makeQuery(id: 11, name: "ads.example.com", type: DNSRecordType.txt.rawValue)
        XCTAssertEqual(try DNSMessage.parse(DNSMessage.blockedResponse(to: qtxt, mode: .nullIP)!).answers.count, 0)
        XCTAssertEqual(try DNSMessage.parse(DNSMessage.blockedResponse(to: q6, mode: .refused)!).rcode, DNSRCode.refused.rawValue)
        XCTAssertEqual(try DNSMessage.parse(DNSMessage.servFail(to: q6)!).rcode, DNSRCode.servFail.rawValue)
    }

    func testAddressResponseAndHTTPSAlias() throws {
        let q = DNSMessage.makeQuery(id: 3, name: "dns.quad9.net", type: DNSRecordType.a.rawValue)
        let r = try DNSMessage.parse(DNSMessage.addressResponse(to: q, addresses: ["9.9.9.9", "2620:fe::fe"])!)
        XCTAssertEqual(r.addresses, ["9.9.9.9"])
        // HTTPS RR whose TargetName points at a tracker.
        var out: [UInt8] = [0, 5, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        out += DNSMessage.encodeName("www.shop.com") + [0, 65, 0, 1]
        let rdata: [UInt8] = [0, 1] + DNSMessage.encodeName("svc.tracker-network.net")
        out += [0xC0, 0x0C, 0, 65, 0, 1, 0, 0, 0, 60, 0, UInt8(rdata.count)] + rdata
        let m = try DNSMessage.parse(Data(out))
        XCTAssertEqual(m.aliasChain(for: "www.shop.com"), ["svc.tracker-network.net"])
    }

    func testMalformedInputIsRejected() {
        XCTAssertThrowsError(try DNSMessage.parse(Data([0, 1, 2])))
        // Compression pointer pointing at itself.
        let loop: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1]
        XCTAssertThrowsError(try DNSMessage.parse(Data(loop)))
        XCTAssertNil(DNSMessage.blockedResponse(to: Data([1, 2, 3]), mode: .nxdomain))
    }
}
