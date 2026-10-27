// SPDX-License-Identifier: MIT
import XCTest
@testable import ShieldCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The C bind(2) (a type in scope can have its own `bind` method).
func posixBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.bind(fd, addr, len)
    #else
    return Darwin.bind(fd, addr, len)
    #endif
}

func net(_ s: String) -> NetworkRule { RuleParser.parseLine(s).network! }
func cos(_ s: String) -> CosmeticRule { RuleParser.parseLine(s).cosmetic! }

final class SafariConverterTests: XCTestCase {
    func testURLFilterConversion() {
        let host = SafariConverter.urlFilter(for: net("||ads.example.com^"))!
        XCTAssertEqual(host, "^[htpsw]+:\\/\\/([a-z0-9_-]+\\.)*ads\\.example\\.com[/:?=&]")
        let re = try! NSRegularExpression(pattern: host, options: [.caseInsensitive])
        for (url, hit) in [("https://ads.example.com/x", true), ("https://a.b.ads.example.com/", true),
                           ("https://ads.example.com.evil.org/", false), ("https://notads.example.com/", false)] {
            XCTAssertEqual(re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, hit, url)
        }
        XCTAssertEqual(SafariConverter.urlFilter(for: net("/banner/*/img^")), "\\/banner\\/.*\\/img[/:?=&]")
        XCTAssertEqual(SafariConverter.urlFilter(for: net("|https://x.com/ad.js|")), "^https:\\/\\/x\\.com\\/ad\\.js$")
        XCTAssertEqual(SafariConverter.urlFilter(for: net("/ad[0-9]+\\.gif/")), "ad[0-9]+\\.gif")
        XCTAssertEqual(SafariConverter.urlFilter(for: net("/ad\\d+/")), "ad[0-9]+")
        XCTAssertNil(SafariConverter.urlFilter(for: net("/(ads|banners)\\.js/")), "alternation isn't supported")
        XCTAssertNil(SafariConverter.urlFilter(for: net("/a{2,}/")))
        XCTAssertNil(SafariConverter.urlFilter(for: net("/(?!x)ad/")))
    }

    func testTriggersAndActions() {
        let c = SafariConverter.convert(network: [
            net("||tracker.com^$third-party,script,domain=news.com|blog.com"),
            net("@@||site.com^$document"),
            net("@@||ok.tracker.com^"),
        ], cosmetic: [], chunkSize: 100, chunkCount: 1)
        let rules = c.chunks[0]
        XCTAssertEqual(rules[0].action.type, "block")
        XCTAssertEqual(rules[0].trigger.loadType, ["third-party"])
        XCTAssertEqual(rules[0].trigger.resourceType, ["script"])
        XCTAssertEqual(rules[0].trigger.ifDomain, ["*news.com", "*blog.com"])
        let doc = rules.first { $0.trigger.ifDomain == ["*site.com"] }!
        XCTAssertEqual(doc.action.type, "ignore-previous-rules")
        XCTAssertEqual(doc.trigger.urlFilter, ".*")
        XCTAssertEqual(rules.last?.action.type, "ignore-previous-rules", "exceptions come after blocks")
        let json = String(decoding: SafariConverter.json(rules), as: UTF8.self)
        XCTAssertTrue(json.contains("\"url-filter\""))
        XCTAssertTrue(json.contains("\"if-domain\""))
        XCTAssertTrue(json.contains("\"load-type\""))
    }

    func testSplittingKeepsExceptionsInEveryChunk() {
        let blocks = (0..<25).map { net("||b\($0).com^") }
        let exceptions = (0..<3).map { net("@@||e\($0).b1.com^") }
        let c = SafariConverter.convert(network: blocks + exceptions, cosmetic: [], chunkSize: 10, chunkCount: 6)
        XCTAssertEqual(c.chunks.count, 6, "unused blockers get a placeholder list")
        // 25 blocks spread evenly over 6 blockers → 5 per chunk (+3 exceptions each).
        for chunk in c.chunks.prefix(5) {
            XCTAssertLessThanOrEqual(chunk.count, 10)
            XCTAssertEqual(chunk.suffix(3).map { $0.action.type }, Array(repeating: "ignore-previous-rules", count: 3))
            XCTAssertFalse(chunk.prefix(chunk.count - 3).contains { $0.action.type == "ignore-previous-rules" })
        }
        XCTAssertEqual(c.chunks[5].count, 1)
        XCTAssertEqual(c.dropped, 0)
        XCTAssertEqual(c.chunks.prefix(5).reduce(0) { $0 + $1.count - 3 }, 25)

        let tight = SafariConverter.convert(network: blocks, cosmetic: [], chunkSize: 5, chunkCount: 2)
        XCTAssertEqual(tight.dropped, 15)
        XCTAssertLessThanOrEqual(tight.totalRules, 10)
    }

    func testCosmeticConversion() {
        var cs = (0..<300).map { cos("##.ad-\($0)") }
        cs += [cos("news.com,blog.com##.sponsored"), cos("##.promo"), cos("shop.com#@#.promo"),
               cos("example.com##div:has-text(Ad)"), cos("##.bad{selector"), cos("example.*##.x")]
        let c = SafariConverter.convert(network: [], cosmetic: cs, chunkSize: 1000, chunkCount: 1)
        let hides = c.chunks[0].filter { $0.action.type == "css-display-none" }
        XCTAssertEqual(hides.filter { $0.trigger.ifDomain == nil && $0.trigger.unlessDomain == nil }.count, 2, "300 generic selectors batch into 2 rules")
        XCTAssertTrue(hides.contains { $0.trigger.ifDomain == ["*blog.com", "*news.com"] && $0.action.selector == ".sponsored" })
        XCTAssertTrue(hides.contains { $0.trigger.unlessDomain == ["*shop.com"] && $0.action.selector == ".promo" })
        XCTAssertGreaterThanOrEqual(c.skipped["procedural/style cosmetic (WebExtension handles it)"] ?? 0, 1)
        XCTAssertEqual(c.skipped["selector not safe for Safari"], 1)
        XCTAssertEqual(c.skipped["entity domain (example.*)"], 1)
    }
}

final class DNRTests: XCTestCase {
    func testGroupingAndPriorities() {
        var rules = (0..<2500).map { net("||h\($0).com^") }
        rules += [net("@@||ok.h1.com^"), net("||imp.com^$important"), net("@@||site.com^$document"),
                  net("/ads/*$script,third-party,domain=news.com"), net("/track[0-9]+/"), net("/(?=x)y/")]
        let c = DNRConverter.convert(network: rules, rulesPerRuleset: 3)
        let all = c.rulesets.flatMap { $0.rules }
        XCTAssertEqual(Set(all.map { $0.id }).count, all.count, "ids are unique")
        let grouped = all.filter { $0.condition.requestDomains != nil && $0.action.type == "block" && $0.priority == 1 }
        XCTAssertEqual(grouped.count, 3, "2,500 hosts → 3 rules of ≤1,000")
        XCTAssertEqual(grouped.reduce(0) { $0 + ($1.condition.requestDomains?.count ?? 0) }, 2500)
        XCTAssertTrue(all.contains { $0.action.type == "allow" && $0.priority == 2 && $0.condition.requestDomains == ["ok.h1.com"] })
        XCTAssertTrue(all.contains { $0.action.type == "block" && $0.priority == 4 && $0.condition.requestDomains == ["imp.com"] })
        XCTAssertTrue(all.contains { $0.action.type == "allowAllRequests" && $0.priority == 3 && $0.condition.resourceTypes == ["main_frame", "sub_frame"] })
        let scoped = all.first { $0.condition.urlFilter == "/ads/*" }!
        XCTAssertEqual(scoped.condition.domainType, "thirdParty")
        XCTAssertEqual(scoped.condition.initiatorDomains, ["news.com"])
        XCTAssertEqual(scoped.condition.resourceTypes, ["script"])
        XCTAssertEqual(c.regexCount, 1)
        XCTAssertEqual(c.skipped["regex not RE2-compatible"], 1)
        XCTAssertTrue(c.rulesets.allSatisfy { $0.rules.count <= 3 })
        XCTAssertEqual(c.rulesets.first?.id, "swoop_1")
    }
}

final class CosmeticCompilerTests: XCTestCase {
    func testBundle() {
        let lines = ["##.ad-box", "###top-ad", "##div > .ad", "news.com##.promo", "news.com#@#.ad-box",
                     "shop.com#?#div:has-text(Sponsored)", "youtube.com##+js(set-constant, a.b, undefined)",
                     "x.com##+js(unknown-scriptlet)", "@@||quiet.com^$generichide", "@@||whole.com^$elemhide"]
        var c: [CosmeticRule] = [], s: [ScriptletRule] = [], n: [NetworkRule] = []
        for l in lines {
            let p = RuleParser.parseLine(l)
            if let x = p.cosmetic { c.append(x) }
            s += p.scriptlets
            if let x = p.network { n.append(x) }
        }
        let (b, skipped) = CosmeticCompiler.compile(cosmetic: c, scriptlets: s, network: n)
        XCTAssertEqual(b.genericClasses["ad-box"], [".ad-box"])
        XCTAssertEqual(b.genericIds["top-ad"], ["#top-ad"])
        XCTAssertEqual(b.genericComplex, ["div > .ad"])
        XCTAssertEqual(b.specific["news.com"], [".promo"])
        XCTAssertEqual(b.exceptions["news.com"], [".ad-box"])
        XCTAssertEqual(b.procedural["shop.com"], ["div:has-text(Sponsored)"])
        XCTAssertEqual(b.scriptlets["youtube.com"], [["set-constant", "a.b", "undefined"]])
        XCTAssertEqual(skipped["scriptlet unknown-scriptlet"], 1)
        XCTAssertEqual(b.genericHide, ["quiet.com"])
        XCTAssertEqual(b.elemHide, ["whole.com"])
    }
}

final class PolicyAndEngineTests: XCTestCase {
    func testEncryptedDNSPolicy() {
        let p = EncryptedDNSPolicy(mode: .blockBypass, blockPrivateRelay: true,
                                   upstreamHosts: ["dns.quad9.net"], upstreamIPs: ["9.9.9.9"])
        XCTAssertTrue(p.queryVerdict("use-application-dns.net").isBlocked)
        XCTAssertTrue(p.queryVerdict("mozilla.cloudflare-dns.com").isBlocked)
        XCTAssertTrue(p.queryVerdict("dns.google").isBlocked)
        XCTAssertTrue(p.queryVerdict("mask.icloud.com").isBlocked)
        XCTAssertFalse(p.queryVerdict("dns.quad9.net").isBlocked, "Shield's own upstream is exempt")
        XCTAssertFalse(p.queryVerdict("www.google.com").isBlocked)
        XCTAssertNotEqual(p.flowVerdict(remoteIP: "1.2.3.4", remoteHostname: nil, port: 853, proto: .tcp), .allow)
        XCTAssertNotEqual(p.flowVerdict(remoteIP: "8.8.8.8", remoteHostname: nil, port: 443, proto: .udp), .allow)
        XCTAssertNotEqual(p.flowVerdict(remoteIP: "2001:4860:4860:0::8888", remoteHostname: nil, port: 443, proto: .tcp), .allow)
        XCTAssertNotEqual(p.flowVerdict(remoteIP: "5.6.7.8", remoteHostname: "doh.opendns.com", port: 443, proto: .tcp), .allow)
        XCTAssertEqual(p.flowVerdict(remoteIP: "9.9.9.9", remoteHostname: nil, port: 853, proto: .tcp), .allow)
        XCTAssertEqual(p.flowVerdict(remoteIP: "142.250.1.1", remoteHostname: "www.google.com", port: 443, proto: .tcp), .allow)
        XCTAssertEqual(p.flowVerdict(remoteIP: "8.8.8.8", remoteHostname: nil, port: 53, proto: .udp), .allow)
        let off = EncryptedDNSPolicy(mode: .allow)
        XCTAssertFalse(off.queryVerdict("dns.google").isBlocked)
        XCTAssertEqual(off.flowVerdict(remoteIP: "8.8.8.8", remoteHostname: nil, port: 853, proto: .tcp), .allow)
        XCTAssertFalse(EncryptedDNSPolicy().queryVerdict("mask.icloud.com").isBlocked, "Private Relay opt-out is off by default")
    }

    func testEnginePausesAndPrecedence() throws {
        let idx = try makeIndex([("l", "||ads.example.com^\n||tracker.net^")])
        var cfg = ShieldConfig()
        cfg.allowlist = ["dns.google"]
        let e = ShieldEngine(config: cfg, index: idx)
        let now = Date()
        XCTAssertEqual(e.decide(name: "ads.example.com", now: now).action, .blocked)
        XCTAssertEqual(e.decide(name: "dns.google", now: now).action, .allowed, "allowlist beats the bypass policy")
        XCTAssertEqual(e.decide(name: "cloudflare-dns.com", now: now).info?.source, "doh-policy")
        XCTAssertEqual(e.decide(name: "www.apple.com", now: now).action, .passed)

        cfg.pausedUntil = now.addingTimeInterval(300)
        e.update(config: cfg)
        XCTAssertEqual(e.decide(name: "ads.example.com", now: now).note, "paused")
        XCTAssertEqual(e.decide(name: "ads.example.com", now: now.addingTimeInterval(301)).action, .blocked, "pause runs out")

        cfg.pausedUntil = nil
        cfg.appPauses = [AppPause(id: "com.google.Chrome", name: "Chrome", until: nil)]
        cfg.sitePauses = [SitePause(domain: "tracker.net", until: now.addingTimeInterval(60))]
        e.update(config: cfg)
        XCTAssertEqual(e.decide(name: "ads.example.com", app: "com.google.Chrome", now: now).note, "app paused")
        XCTAssertEqual(e.decide(name: "ads.example.com", app: "com.apple.Safari", now: now).action, .blocked)
        XCTAssertEqual(e.decide(name: "x.tracker.net", now: now).info?.source, "site-pause")
        XCTAssertEqual(e.decide(name: "x.tracker.net", now: now.addingTimeInterval(61)).action, .blocked)
        XCTAssertEqual(cfg.pruned(at: now.addingTimeInterval(61)).sitePauses, [])

        cfg.enabled = false
        e.update(config: cfg)
        XCTAssertEqual(e.decide(name: "ads.example.com", now: now).note, "off")
    }

    func testFlowVerdicts() throws {
        let e = ShieldEngine(index: try makeIndex([("l", "||ads.example.com^")]))
        XCTAssertNotEqual(e.flowVerdict(remoteIP: "1.2.3.4", remoteHostname: "x.ads.example.com", port: 443, proto: .tcp, app: nil), .allow)
        XCTAssertEqual(e.flowVerdict(remoteIP: "1.2.3.4", remoteHostname: "www.example.com", port: 443, proto: .tcp, app: nil), .allow)
        XCTAssertNotEqual(e.flowVerdict(remoteIP: "8.8.4.4", remoteHostname: nil, port: 443, proto: .tcp, app: nil), .allow)
        var cfg = ShieldConfig(); cfg.appPauses = [AppPause(id: "com.app", name: "App")]
        e.update(config: cfg)
        XCTAssertEqual(e.flowVerdict(remoteIP: "8.8.4.4", remoteHostname: nil, port: 443, proto: .tcp, app: "com.app"), .allow)
    }

    func testHandleQueryProducesBlockedAnswer() throws {
        var cfg = ShieldConfig(); cfg.blockResponse = .nullIP
        let e = ShieldEngine(config: cfg, index: try makeIndex([("l", "||ads.example.com^")]))
        let q = DNSMessage.makeQuery(id: 5, name: "ads.example.com", type: DNSRecordType.a.rawValue)
        let (d, question, answer) = e.handleQuery(q, app: nil)
        XCTAssertEqual(d.action, .blocked)
        XCTAssertEqual(question?.name, "ads.example.com")
        XCTAssertEqual(try DNSMessage.parse(answer!).addresses, ["0.0.0.0"])
    }

    func testStatsCollector() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let c = ShieldStatsCollector(now: day1, logCapacity: 3, calendar: cal)
        let blocked = ShieldDecision(action: .blocked, info: MatchInfo(source: "hagezi-pro", rule: "||a.com^"), note: nil)
        let cname = ShieldDecision(action: .blocked, info: MatchInfo(source: "cname", rule: "||t.net^", cnameTarget: "x.t.net"), note: nil)
        for _ in 0..<3 { c.record(name: "a.com", type: "A", app: "com.apple.Safari", decision: blocked, keepLog: true, now: day1) }
        c.record(name: "m.site.com", type: "A", app: nil, decision: cname, keepLog: true, now: day1)
        c.record(name: "ok.com", type: "A", app: nil, decision: .pass, keepLog: true, now: day1)
        var s = c.snapshot()
        XCTAssertEqual(s.queriesToday, 5)
        XCTAssertEqual(s.blockedToday, 4)
        XCTAssertEqual(s.cnameBlockedTotal, 1)
        XCTAssertEqual(s.topBlocked.first, CountedName(name: "a.com", count: 3))
        XCTAssertEqual(s.topApps.first?.name, "com.apple.Safari")
        XCTAssertEqual(s.bySource["hagezi-pro"], 3)
        XCTAssertEqual(c.entries().map { $0.name }, ["a.com", "m.site.com", "ok.com"], "ring buffer keeps the newest 3")
        XCTAssertEqual(c.entries(after: c.entries()[1].id).map { $0.name }, ["ok.com"])
        c.record(name: "b.com", type: "A", app: nil, decision: blocked, keepLog: false, now: day1.addingTimeInterval(86_400))
        s = c.snapshot()
        XCTAssertEqual(s.queriesToday, 1, "counters roll over at midnight")
        XCTAssertEqual(s.queriesTotal, 6)
        XCTAssertEqual(c.entries().count, 3, "keepLog=false doesn't log")
        XCTAssertEqual(ShieldStats.compact(999), "999")
        XCTAssertEqual(ShieldStats.compact(1200), "1.2k")
        XCTAssertEqual(ShieldStats.compact(45_000), "45k")
        XCTAssertEqual(ShieldStats.compact(2_000_000), "2M")
        XCTAssertEqual(ShieldStats.decode(s.encoded())?.queriesTotal, 6)
    }

    func testConfigCodable() {
        var c = ShieldConfig()
        c.customRules = "||x.com^"
        c.upstream = .doh(url: "https://dns.quad9.net/dns-query", bootstrapIPs: ["9.9.9.9"])
        c.appPauses = [AppPause(id: "a", name: "A", until: Date(timeIntervalSince1970: 100))]
        XCTAssertEqual(ShieldConfig.decode(c.encoded()), c)
        let partial = ShieldConfig.decode(Data("{\"enabled\": false, \"future\": 1}".utf8))
        XCTAssertEqual(partial?.enabled, false)
        XCTAssertEqual(partial?.enabledLists, FilterListCatalog.defaultEnabledIDs)
        XCTAssertEqual(c.upstream.hosts, ["dns.quad9.net"])
    }
}

final class ListIntegrityTests: XCTestCase {
    let src = FilterListSource(id: "t", name: "T", summary: "", category: .ads, urls: ["https://easylist.to/t.txt"],
                               homepage: "", licence: "", licenceURL: "", dns: true, browser: true, defaultEnabled: true,
                               minRules: 3, expectedTitle: "Test List", parser: .browserList)
    let good = "! Title: Test List\n! Expires: 2 hours\n! Version: 7\n||a.com^\n||b.com^\n||c.com^\n##.ad\n"

    func testAcceptsAndRecords() throws {
        let r = ListIntegrity.verify(data: Data(good.utf8), source: src, fetchedFrom: src.urls[0], previous: nil)
        guard case .success(let (rec, _)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rec.ruleCount, 4)
        XCTAssertEqual(rec.dnsRuleCount, 3)
        XCTAssertEqual(rec.title, "Test List")
        XCTAssertEqual(rec.version, "7")
        XCTAssertEqual(rec.expiresSeconds, 7200)
        XCTAssertEqual(rec.sha256, SHA256.hash(Data(good.utf8)).hex)
        XCTAssertEqual(ListIntegrity.nextUpdate(after: rec), rec.fetchedAt.addingTimeInterval(6 * 3600), "never more often than 6 h")
    }

    func testRejections() {
        func fail(_ text: String, prev: ListRecord? = nil, sha: String? = nil, url: String? = nil) -> ListRejection? {
            if case .failure(let e) = ListIntegrity.verify(data: Data(text.utf8), source: src, fetchedFrom: url ?? src.urls[0],
                                                          previous: prev, expectedSHA256: sha) { return e }
            return nil
        }
        XCTAssertEqual(fail("<!DOCTYPE html><html><head><title>Login to Wi-Fi</title></head><body>" + String(repeating: "x", count: 100)), .looksLikeHTML)
        XCTAssertEqual(fail("tiny"), .tooSmall(4))
        guard case .wrongTitle? = fail(good.replacingOccurrences(of: "Test List", with: "Other")) else { return XCTFail() }
        guard case .tooFewRules? = fail("! Title: Test List\n||a.com^\n" + String(repeating: "! pad\n", count: 20)) else { return XCTFail() }
        let prev = ListRecord(id: "t", sha256: "", ruleCount: 100, dnsRuleCount: 100, fetchedAt: Date(), title: nil,
                              version: nil, expiresSeconds: nil, sourceURL: "")
        guard case .suddenDrop? = fail(good, prev: prev) else { return XCTFail() }
        guard case .hashMismatch? = fail(good, sha: String(repeating: "0", count: 64)) else { return XCTFail() }
        XCTAssertEqual(fail(good, url: "https://evil.example/list.txt"), .disallowedHost("evil.example"))
    }

    func testSignedManifest() throws {
        let m = "{\"version\":1,\"generated\":\"2026-10-26T12:00:00Z\",\"lists\":{\"easylist\":{\"sha256\":\"ab\",\"rules\":5}}}"
        let ok = try ListManifest.load(data: Data(m.utf8), signature: Data([1])) { _, sig in sig == Data([1]) }
        XCTAssertEqual(ok.lists["easylist"]?.rules, 5)
        XCTAssertThrowsError(try ListManifest.load(data: Data(m.utf8), signature: Data([2])) { _, sig in sig == Data([1]) })
    }
}

final class CompilerTests: XCTestCase {
    func testEndToEnd() throws {
        let dnsList = FilterListCatalog.source(id: "hagezi-pro")!
        let browserList = FilterListCatalog.source(id: "easylist")!
        let compiled = try ShieldCompiler.compile([
            ListText(source: dnsList, text: "! Title: HaGeZi\n||tracker.one^\n||tracker.two^\n||dead.example^"),
            ListText(source: browserList, text: "! Title: EasyList\n||adserver.com^\n||ads.cdn.com^$third-party\n##.ad\nnews.com##.promo\n||dead.example^$badfilter"),
        ])
        let idx = try ShieldIndex(data: compiled.index)
        XCTAssertEqual(Set(idx.sources), ["hagezi-pro", "easylist"])
        let m = DomainMatcher(lists: idx)
        XCTAssertTrue(m.match("x.tracker.one").isBlocked)
        XCTAssertTrue(m.match("adserver.com").isBlocked)
        XCTAssertFalse(m.match("ads.cdn.com").isBlocked, "$third-party stays browser-only")
        XCTAssertFalse(m.match("dead.example").isBlocked, "$badfilter from any list applies")
        XCTAssertGreaterThan(compiled.safari!.totalRules, 0)
        XCTAssertGreaterThan(compiled.dnr!.totalRules, 0)
        XCTAssertEqual(compiled.cosmetic!.specific["news.com"], [".promo"])
        XCTAssertNotNil(compiled.cosmetic!.scriptlets["youtube.com"], "built-in YouTube rules are included")
        XCTAssertEqual(compiled.report.lists.count, 3)
    }

    func testProfileBuilder() throws {
        let xml = DNSProfileBuilder.profile(name: "AdGuard <DNS>", url: "https://dns.adguard-dns.com/dns-query", addresses: ["94.140.14.14"])
        let plist = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
        let content = (plist?["PayloadContent"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["PayloadType"] as? String, "com.apple.dnsSettings.managed")
        let dns = content?["DNSSettings"] as? [String: Any]
        XCTAssertEqual(dns?["DNSProtocol"] as? String, "HTTPS")
        XCTAssertEqual(dns?["ServerAddresses"] as? [String], ["94.140.14.14"])
        XCTAssertTrue((plist?["PayloadDisplayName"] as? String)?.contains("<DNS>") ?? false)
    }

    func testCatalogIsConsistent() {
        let ids = FilterListCatalog.all.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ["easylist", "easyprivacy", "adguard-dns", "hagezi-pro", "hagezi-multi", "oisd-big", "peter-lowe", "urlhaus"] {
            XCTAssertNotNil(FilterListCatalog.source(id: id), id)
        }
        for l in FilterListCatalog.all {
            XCTAssertFalse(l.licence.isEmpty)
            XCTAssertTrue(l.urls.allSatisfy { $0.hasPrefix("https://") }, l.id)
        }
        XCTAssertTrue(FilterListCatalog.allowedHosts.contains("cdn.jsdelivr.net"))
    }
}

/// Runs the real UDP/TCP server against a fake upstream on loopback.
final class LocalResolverTests: XCTestCase {
    final class FakeUpstream {
        let fd: Int32
        let port: UInt16
        var running = true
        init?(answer: @escaping (Data) -> Data?) {
            #if os(Linux)
            let s = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
            #else
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            #endif
            guard s >= 0, let addr = SocketAddress(host: "127.0.0.1", port: 0) else { return nil }
            guard addr.withSockaddr({ posixBind(s, $0, $1) }) == 0 else { return nil }
            var sin = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
            fd = s
            port = UInt16(bigEndian: sin.sin_port)
            Thread { [self] in
                var buf = [UInt8](repeating: 0, count: 2048)
                while self.running {
                    guard DNSForwarder.waitReadable(s, 0.2) else { continue }
                    var from = sockaddr_storage()
                    var flen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &buf, buf.count, 0, $0, &flen) } }
                    guard n > 0, let reply = answer(Data(buf[0..<n])) else { continue }
                    _ = reply.withUnsafeBytes { b in withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, b.baseAddress, reply.count, 0, $0, flen) } } }
                }
                close(s)
            }.start()
        }
    }

    func testServerBlocksForwardsAndUncloaks() throws {
        guard let upstream = FakeUpstream(answer: { q in
            guard let m = try? DNSMessage.parse(q), let name = m.questions.first?.name else { return nil }
            var r = name.hasPrefix("metrics.") ? TestDNS.cnameResponse(query: name, chain: ["c.tracker-network.net"], ip: [5, 6, 7, 8])
                                               : TestDNS.cnameResponse(query: name, chain: [], ip: [1, 1, 1, 1])
            r[0] = q[0]; r[1] = q[1]
            return r
        }) else { throw XCTSkip("no loopback sockets") }
        defer { upstream.running = false }
        let engine = ShieldEngine(index: try makeIndex([("l", "||ads.example.com^\n||tracker-network.net^")]))
        let fwd = DNSForwarder(engine: engine, upstreams: [.udp(SocketAddress(host: "127.0.0.1", port: upstream.port)!)], timeout: 2)
        let server = LocalDNSServer(forwarder: fwd)
        let port = try server.listen("127.0.0.1:0")
        server.start()
        defer { server.stop() }
        let addr = SocketAddress(host: "127.0.0.1", port: port)!

        func ask(_ name: String, tcp: Bool = false) -> DNSMessage? {
            let q = DNSMessage.makeQuery(id: UInt16.random(in: 1...60000), name: name, type: DNSRecordType.a.rawValue)
            let r = tcp ? DNSForwarder.queryTCP(q, addr, 3) : DNSForwarder.queryUDP(q, addr, 3)
            return r.flatMap { try? DNSMessage.parse($0) }
        }
        let blocked = ask("x.ads.example.com")
        XCTAssertEqual(blocked?.rcode, DNSRCode.nxDomain.rawValue)
        let ok = ask("www.example.org")
        XCTAssertEqual(ok?.rcode, 0)
        XCTAssertEqual(ok?.addresses, ["1.1.1.1"])
        let cloaked = ask("metrics.shop.com")
        XCTAssertEqual(cloaked?.rcode, DNSRCode.nxDomain.rawValue, "CNAME to a listed tracker is blocked")
        XCTAssertEqual(ask("www.example.org", tcp: true)?.addresses, ["1.1.1.1"], "DNS over TCP works too")
        XCTAssertEqual(ask("use-application-dns.net")?.rcode, DNSRCode.nxDomain.rawValue)
        let s = engine.stats.snapshot()
        XCTAssertEqual(s.queriesTotal, 5)
        XCTAssertEqual(s.blockedTotal, 3)
        XCTAssertEqual(s.cnameBlockedTotal, 1)
    }

    func testUpstreamFailureGivesServfail() throws {
        let engine = ShieldEngine()
        let fwd = DNSForwarder(engine: engine, upstreams: [], timeout: 0.5)
        let q = DNSMessage.makeQuery(id: 1, name: "example.com", type: 1)
        XCTAssertEqual(try DNSMessage.parse(fwd.resolve(q)!).rcode, DNSRCode.servFail.rawValue)
        XCTAssertEqual(SocketAddress("[::1]:5353")?.port, 5353)
        XCTAssertEqual(SocketAddress("9.9.9.9")?.port, 53)
        XCTAssertNil(SocketAddress("not-an-ip"))
    }
}
