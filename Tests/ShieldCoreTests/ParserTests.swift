// SPDX-License-Identifier: MIT
import XCTest
@testable import ShieldCore

final class RuleParserTests: XCTestCase {
    func p(_ s: String, _ o: RuleParserOptions = .browserList) -> ParsedLine { RuleParser.parseLine(s, options: o) }

    func testABPHostRuleFeedsDNSAndBrowser() {
        let r = p("||ads.example.com^")
        XCTAssertEqual(r.dns, DNSRule(pattern: HostPattern(.subtree, "ads.example.com")))
        XCTAssertEqual(r.network?.pattern, "||ads.example.com^")
        XCTAssertEqual(r.network?.plainHost, "ads.example.com")
        XCTAssertNil(r.error)
    }

    func testExceptionAndImportant() {
        let e = p("@@||cdn.example.com^")
        XCTAssertEqual(e.dns?.isException, true)
        XCTAssertEqual(e.network?.isException, true)
        let i = p("||tracker.net^$important")
        XCTAssertEqual(i.dns?.important, true)
        XCTAssertEqual(i.network?.important, true)
    }

    func testBrowserOnlyModifiersStayOutOfDNS() {
        let r = p("||doubleclick.net^$third-party")
        XCTAssertNil(r.dns, "$third-party can't be applied at DNS level")
        XCTAssertEqual(r.network?.thirdParty, true)
        let s = p("||example.com/ads/banner.js$script,domain=news.com|~shop.news.com")
        XCTAssertNil(s.dns)
        XCTAssertEqual(s.network?.resourceTypes, [.script])
        XCTAssertEqual(s.network?.includeDomains, ["news.com"])
        XCTAssertEqual(s.network?.excludeDomains, ["shop.news.com"])
        XCTAssertNil(p("||ads.example.com^$client=192.168.1.5", .dnsList).dns, "AdGuard Home $client isn't supported")
    }

    func testDNSModifiers() {
        let r = p("||example.org^$denyallow=good.example.org|fine.example.org,dnstype=AAAA|~A", .dnsList)
        XCTAssertEqual(r.dns?.denyAllow, ["good.example.org", "fine.example.org"])
        XCTAssertEqual(r.dns?.dnsTypes, ["aaaa"])
        XCTAssertEqual(r.dns?.excludedDNSTypes, ["a"])
        XCTAssertTrue(r.dns!.isComplex)
        XCTAssertTrue(r.dns!.applies(toType: "AAAA"))
        XCTAssertFalse(r.dns!.applies(toType: "A"))
    }

    func testBadfilter() {
        let r = p("||ads.example.com^$badfilter")
        XCTAssertNil(r.dns)
        XCTAssertEqual(r.badfilterDNS, DNSRule(pattern: HostPattern(.subtree, "ads.example.com")))
        XCTAssertNotNil(r.badfilterNetwork)
    }

    func testHostsSyntax() {
        XCTAssertEqual(p("0.0.0.0 ads.example.com").dns, DNSRule(pattern: HostPattern(.exact, "ads.example.com")))
        XCTAssertEqual(p("127.0.0.1\tTracker.Example.NET # comment").dns?.pattern.value, "tracker.example.net")
        XCTAssertEqual(p(":: ipv6.example.com").dns?.pattern.kind, .exact)
        XCTAssertTrue(p("127.0.0.1 localhost").isComment)
        XCTAssertEqual(RuleParser.hostsEntries("0.0.0.0 a.com b.com localhost")?.map { $0.pattern.value }, ["a.com", "b.com"])
        XCTAssertNil(RuleParser.hostsEntries("||a.com^"))
    }

    func testPlainDomainsAndWildcards() {
        XCTAssertEqual(p("tracker.example.com", .dnsList).dns?.pattern, HostPattern(.subtree, "tracker.example.com"))
        XCTAssertEqual(p("tracker.example.com", RuleParserOptions(plainDomainIsSubtree: false)).dns?.pattern.kind, .exact)
        XCTAssertEqual(p("||ad*.example.com^").dns?.pattern, HostPattern(.wildcard, "ad*.example.com"))
        XCTAssertEqual(p("*.example.com", .dnsList).dns?.pattern, HostPattern(.wildcard, "*.example.com"))
        XCTAssertEqual(p("|https://exact.example.com^").dns?.pattern, HostPattern(.exact, "exact.example.com"))
        XCTAssertNil(p("||1.2.3.4^").dns, "IP rules don't apply to DNS lookups")
        XCTAssertNil(p("||com^").dns, "a bare TLD is never blocked")
    }

    func testRegexDependsOnListKind() {
        let dnsR = p("/^ad[0-9]+\\.example\\.com$/", .dnsList)
        XCTAssertEqual(dnsR.dns?.pattern.kind, .regex)
        XCTAssertNil(dnsR.network)
        let br = p("/banner[0-9]+\\.gif/$image")
        XCTAssertNil(br.dns)
        XCTAssertEqual(br.network?.isRegex, true)
        XCTAssertEqual(br.network?.resourceTypes, [.image])
        XCTAssertNotNil(p("/[unclosed/").error)
    }

    func testPathRulesStartingWithSlashAreNotRegex() {
        let r = p("/88/tag.min.js")
        XCTAssertNil(r.error)
        XCTAssertEqual(r.network?.isRegex, false)
        XCTAssertEqual(r.network?.pattern, "/88/tag.min.js")
        XCTAssertEqual(p("/a/display.php?$script").network?.resourceTypes, [.script])
    }

    func testCommentsAndMetadata() {
        XCTAssertTrue(p("! just a comment").isComment)
        XCTAssertTrue(p("[Adblock Plus 2.0]").isComment)
        XCTAssertTrue(p("# hosts comment").isComment)
        XCTAssertEqual(p("! Title: EasyList").metadata?.value, "EasyList")
        XCTAssertEqual(p("! Expires: 4 days (update frequency)").metadata?.key, "expires")
        XCTAssertEqual(RuleParser.expiresSeconds("4 days (update frequency)"), 4 * 86_400)
        XCTAssertEqual(RuleParser.expiresSeconds("12 hours"), 12 * 3_600)
        XCTAssertNil(RuleParser.expiresSeconds("soon"))
        XCTAssertTrue(p("").isComment)
    }

    func testUnknownAndUnsupportedModifiers() {
        XCTAssertNotNil(p("||a.com^$frobnicate").error)
        XCTAssertNotNil(p("||a.com/x$csp=script-src 'none'").error)
        XCTAssertNil(p("*$ping,third-party").error, "type-only rules are fine for browsers")
        XCTAssertNotNil(p("*").error)
    }

    func testCosmeticRules() {
        let g = p("##.ad-banner")
        XCTAssertEqual(g.cosmetic, CosmeticRule(selector: ".ad-banner"))
        let s = p("example.com,~shop.example.com##div[id^=\"ad-\"]")
        XCTAssertEqual(s.cosmetic?.includeDomains, ["example.com"])
        XCTAssertEqual(s.cosmetic?.excludeDomains, ["shop.example.com"])
        XCTAssertEqual(p("example.com#@#.ad").cosmetic?.isException, true)
        XCTAssertEqual(p("example.com##div:has-text(Sponsored)").cosmetic?.kind, .procedural)
        XCTAssertEqual(p("example.com#?#div:-abp-has(.ad)").cosmetic?.kind, .procedural)
        XCTAssertEqual(p("example.com##div:has(> .ad)").cosmetic?.kind, .hide, ":has() is native CSS")
        XCTAssertEqual(p("example.com#$#body { overflow: auto !important; }").cosmetic?.kind, .style)
        XCTAssertNil(p("##.ad", .dnsList).cosmetic, "DNS compiles drop cosmetic rules")
        XCTAssertNotNil(p("example.com##^script:has-text(x)").error)
        XCTAssertEqual(p("example.*##.ad").cosmetic?.includeDomains, ["example.*"])
    }

    func testScriptletDialects() {
        let u = p("youtube.com##+js(set-constant, ytInitialPlayerResponse.adPlacements, undefined)")
        XCTAssertEqual(u.scriptlets, [ScriptletRule(includeDomains: ["youtube.com"], name: "set-constant",
                                                    args: ["ytInitialPlayerResponse.adPlacements", "undefined"])])
        let a = p("example.org#%#//scriptlet('abort-on-property-read', 'adblock.check')")
        XCTAssertEqual(a.scriptlets.first?.name, "abort-on-property-read")
        XCTAssertEqual(a.scriptlets.first?.args, ["adblock.check"])
        let abp = p("example.net#$#abort-on-property-write foo; json-prune 'a b' c")
        XCTAssertEqual(abp.scriptlets.map { $0.name }, ["abort-on-property-write", "json-prune"])
        XCTAssertEqual(abp.scriptlets[1].args, ["a b", "c"])
        XCTAssertEqual(p("example.com##+js(aopr, x)").scriptlets.first?.name, "abort-on-property-read")
        XCTAssertEqual(p("example.com##+js(nostif, ad, 2000)").scriptlets.first?.name, "prevent-setTimeout")
        XCTAssertEqual(p("example.com#@#+js(set-constant, x, 1)").scriptlets.first?.isException, true)
        XCTAssertEqual(Scriptlets.canonicalName("ubo-set.js"), "set-constant")
        XCTAssertNotNil(p("example.com#%#window.x=1").error, "raw JS is never run")
    }

    func testUserRuleProblems() {
        let u = UserRules(customRules: "||ok.com^\n||bad.com^$frob\n0.0.0.0 hosts.com\n! comment")
        let probs = u.problems()
        XCTAssertEqual(probs.count, 1)
        XCTAssertEqual(probs.first?.line, 2)
    }
}

final class DomainTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(DomainName.normalize(" Ads.Example.COM. "), "ads.example.com")
        XCTAssertEqual(DomainName.normalize("*.example.com", stripWildcard: true), "example.com")
        XCTAssertNil(DomainName.normalize("bad domain.com"))
        XCTAssertNil(DomainName.normalize("-lead.example.com"))
        XCTAssertNil(DomainName.normalize("a..b"))
        XCTAssertNil(DomainName.normalize(String(repeating: "a", count: 64) + ".com"))
        XCTAssertNotNil(DomainName.normalize("_dmarc.example.com"))
        XCTAssertNotNil(DomainName.normalize("xn--bcher-kva.example"))
    }

    func testSuffixesAndSubdomain() {
        XCTAssertEqual(DomainName.suffixes("a.b.c").map(String.init), ["a.b.c", "b.c", "c"])
        XCTAssertTrue(DomainName.isSubdomain("x.example.com", of: "example.com"))
        XCTAssertTrue(DomainName.isSubdomain("example.com", of: "example.com"))
        XCTAssertFalse(DomainName.isSubdomain("badexample.com", of: "example.com"))
    }

    func testRegistrableDomainAndHosts() {
        XCTAssertEqual(DomainName.registrableDomain("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(DomainName.registrableDomain("a.b.example.com"), "example.com")
        XCTAssertEqual(DomainName.registrableDomain("user.github.io"), "user.github.io")
        XCTAssertEqual(DomainName.host(fromURLOrHost: "https://www.Example.com:8080/path?q=1"), "www.example.com")
        XCTAssertEqual(DomainName.host(fromURLOrHost: "example.org/page"), "example.org")
    }

    func testIPAddresses() {
        XCTAssertEqual(IPAddress.parse("8.8.8.8")?.description, "8.8.8.8")
        XCTAssertEqual(IPAddress.parse("2001:4860:4860:0:0:0:0:8888")?.description, "2001:4860:4860::8888")
        XCTAssertEqual(IPAddress.parse("::1")?.description, "::1")
        XCTAssertEqual(IPAddress.parse("::ffff:1.2.3.4")?.bytes.suffix(4), [1, 2, 3, 4])
        XCTAssertNil(IPAddress.parse("256.1.1.1"))
        XCTAssertNil(IPAddress.parse("1:2:3"))
        XCTAssertNil(IPAddress.parse("example.com"))
    }

    func testGlob() {
        XCTAssertTrue(Glob.match("ad*.example.com", "ad123.example.com"))
        XCTAssertTrue(Glob.match("*.example.com", "a.b.example.com"))
        XCTAssertFalse(Glob.match("*.example.com", "example.com"))
        XCTAssertFalse(Glob.match("ad*.example.com", "bad1.example.com"))
        XCTAssertTrue(Glob.match("putrr*.com", "putrr7.com"))
    }
}

final class CryptoTests: XCTestCase {
    func testSHA256Vectors() {
        XCTAssertEqual(SHA256.hash(Data()).hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hash(Data("abc".utf8)).hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)).hex,
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        var s = SHA256()
        let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: 1000)
        for _ in 0..<1000 { s.update(chunk) }
        XCTAssertEqual(s.finalize().hex, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testIncrementalEqualsOneShot() {
        let data = (0..<1000).map { UInt8($0 % 251) }
        var s = SHA256()
        s.update(Array(data[0..<3])); s.update(Array(data[3..<200])); s.update(Array(data[200...]))
        XCTAssertEqual(s.finalize(), SHA256.hash(data))
    }

    func testBloomFilter() {
        var b = BloomFilter(capacity: 10_000, falsePositiveRate: 0.01)
        for i in 0..<10_000 { b.insert("host\(i).example.com") }
        for i in 0..<10_000 { XCTAssertTrue(b.mightContain("host\(i).example.com")) }
        var fp = 0
        for i in 0..<10_000 where b.mightContain("other\(i).example.net") { fp += 1 }
        XCTAssertLessThan(fp, 300, "false-positive rate should be about 1%")
    }
}

final class ScriptletArgTests: XCTestCase {
    func testBackslashesInRegexArgsSurvive() {
        let r = RuleParser.parseLine("youtube.com##+js(json-prune-fetch-response, a b, , propsToMatch, /\\/(player|get_watch)\\?/)")
        XCTAssertEqual(r.scriptlets.first?.args.last, "/\\/(player|get_watch)\\?/")
        let c = RuleParser.parseLine("example.com##+js(set-constant, a\\, b, 1)")
        XCTAssertEqual(c.scriptlets.first?.args, ["a, b", "1"])
    }
}
