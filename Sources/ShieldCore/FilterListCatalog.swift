// SPDX-License-Identifier: MIT
//
// The filter lists Shield can use. Swoop does not bundle or redistribute any of them: each
// Mac downloads them straight from their maintainers (with mirrors), so every list keeps
// its own licence. Attribution is in the README and in Shield › Filter lists.
import Foundation

public enum ListCategory: String, Codable, CaseIterable {
    case ads = "Ads", privacy = "Trackers", allInOne = "All-in-one", malware = "Malware", telemetry = "Telemetry"
}

public struct FilterListSource: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var category: ListCategory
    public var urls: [String]            // primary first, then mirrors
    public var homepage: String
    public var licence: String
    public var licenceURL: String
    /// Feeds the DNS layer (system-wide).
    public var dns: Bool
    /// Feeds the browser layers (Safari content blockers, WebExtension).
    public var browser: Bool
    public var defaultEnabled: Bool
    /// Rough lower bound used by the sanity check (a "list" of 12 lines is a broken download).
    public var minRules: Int
    /// Expected `! Title:` prefix, when the list has one.
    public var expectedTitle: String?
    public var parser: ParserKind

    public enum ParserKind: String, Codable { case dnsList, browserList }

    public var parserOptions: RuleParserOptions { parser == .dnsList ? .dnsList : .browserList }
}

public enum FilterListCatalog {
    public static let all: [FilterListSource] = [
        FilterListSource(
            id: "hagezi-pro", name: "HaGeZi Multi PRO",
            summary: "Ads, tracking, metrics, telemetry, phishing, malware, scam and crypto-jacking. Extended protection with very few false positives.",
            category: .allInOne,
            urls: ["https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt",
                   "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt",
                   "https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/pro.txt",
                   "https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/adblock/pro.txt"],
            homepage: "https://github.com/hagezi/dns-blocklists", licence: "GPL-3.0",
            licenceURL: "https://github.com/hagezi/dns-blocklists/blob/main/LICENSE",
            dns: true, browser: false, defaultEnabled: true, minRules: 50_000, expectedTitle: "HaGeZi", parser: .dnsList),
        FilterListSource(
            id: "hagezi-multi", name: "HaGeZi Multi NORMAL",
            summary: "The lighter all-round HaGeZi list. Use instead of PRO if a site you need breaks.",
            category: .allInOne,
            urls: ["https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt",
                   "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/multi.txt",
                   "https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/multi.txt"],
            homepage: "https://github.com/hagezi/dns-blocklists", licence: "GPL-3.0",
            licenceURL: "https://github.com/hagezi/dns-blocklists/blob/main/LICENSE",
            dns: true, browser: false, defaultEnabled: false, minRules: 30_000, expectedTitle: "HaGeZi", parser: .dnsList),
        FilterListSource(
            id: "oisd-big", name: "OISD big",
            summary: "Ads, (mobile) app ads, phishing, malvertising, malware, spyware, ransomware, scam, telemetry and tracking.",
            category: .allInOne, urls: ["https://big.oisd.nl"], homepage: "https://oisd.nl", licence: "GPL-3.0",
            licenceURL: "https://github.com/sjhgvr/oisd/blob/main/LICENSE",
            dns: true, browser: false, defaultEnabled: true, minRules: 50_000, expectedTitle: "oisd", parser: .dnsList),
        FilterListSource(
            id: "adguard-dns", name: "AdGuard DNS filter",
            summary: "AdGuard's Base, Mobile Ads and Tracking Protection filters, simplified for DNS.",
            category: .ads, urls: ["https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"],
            homepage: "https://github.com/AdguardTeam/AdGuardSDNSFilter", licence: "GPL-3.0",
            licenceURL: "https://github.com/AdguardTeam/AdGuardSDNSFilter/blob/master/LICENSE",
            dns: true, browser: false, defaultEnabled: true, minRules: 20_000, expectedTitle: "AdGuard DNS filter", parser: .dnsList),
        FilterListSource(
            id: "peter-lowe", name: "Peter Lowe's ad and tracking server list",
            summary: "A small, hand-checked list of ad, tracking and malware servers, maintained since 2001.",
            category: .ads,
            urls: ["https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext"],
            homepage: "https://pgl.yoyo.org/adservers/",
            licence: "Free to use; no formal licence (downloaded from the author, not redistributed)",
            licenceURL: "https://pgl.yoyo.org/adservers/policy.php",
            dns: true, browser: true, defaultEnabled: true, minRules: 1_000, expectedTitle: nil, parser: .dnsList),
        FilterListSource(
            id: "urlhaus", name: "URLhaus malicious URL blocklist",
            summary: "Hosts currently distributing malware, from abuse.ch's URLhaus feed (via malware-filter).",
            category: .malware, urls: ["https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-agh.txt",
                                       "https://curbengh.github.io/malware-filter/urlhaus-filter-agh.txt"],
            homepage: "https://gitlab.com/malware-filter/urlhaus-filter", licence: "CC0-1.0 (data) / MIT (scripts)",
            licenceURL: "https://gitlab.com/malware-filter/urlhaus-filter#license",
            dns: true, browser: false, defaultEnabled: true, minRules: 200, expectedTitle: "Malicious URL Blocklist", parser: .dnsList),
        FilterListSource(
            id: "hagezi-native-microsoft", name: "HaGeZi native tracker: Microsoft",
            summary: "Telemetry built into Microsoft apps (Office, Teams, Edge) on your Mac. May affect some Microsoft features.",
            category: .telemetry,
            urls: ["https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.winoffice.txt",
                   "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.winoffice.txt"],
            homepage: "https://github.com/hagezi/dns-blocklists", licence: "GPL-3.0",
            licenceURL: "https://github.com/hagezi/dns-blocklists/blob/main/LICENSE",
            dns: true, browser: false, defaultEnabled: false, minRules: 100, expectedTitle: "HaGeZi", parser: .dnsList),
        FilterListSource(
            id: "hagezi-native-apple", name: "HaGeZi native tracker: Apple",
            summary: "Apple's own analytics and telemetry hosts. Off by default: can affect some Apple services.",
            category: .telemetry,
            urls: ["https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.apple.txt",
                   "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.apple.txt"],
            homepage: "https://github.com/hagezi/dns-blocklists", licence: "GPL-3.0",
            licenceURL: "https://github.com/hagezi/dns-blocklists/blob/main/LICENSE",
            dns: true, browser: false, defaultEnabled: false, minRules: 20, expectedTitle: "HaGeZi", parser: .dnsList),
        FilterListSource(
            id: "adguard-cname-trackers", name: "AdGuard CNAME-cloaked trackers",
            summary: "Every known disguised (CNAME-cloaked) first-party tracker. Large; the built-in uncloaking already catches the main networks.",
            category: .privacy,
            urls: ["https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_disguised_trackers_justdomains.txt",
                   "https://cdn.jsdelivr.net/gh/AdguardTeam/cname-trackers@master/data/combined_disguised_trackers_justdomains.txt"],
            homepage: "https://github.com/AdguardTeam/cname-trackers", licence: "MIT",
            licenceURL: "https://github.com/AdguardTeam/cname-trackers/blob/master/LICENSE",
            dns: true, browser: false, defaultEnabled: false, minRules: 1_000, expectedTitle: nil, parser: .dnsList),
        FilterListSource(
            id: "easylist", name: "EasyList",
            summary: "The original ad-blocking list: network and cosmetic (element-hiding) rules for web pages.",
            category: .ads, urls: ["https://easylist.to/easylist/easylist.txt",
                                   "https://easylist-downloads.adblockplus.org/easylist.txt"],
            homepage: "https://easylist.to/", licence: "GPL-3.0 or CC BY-SA 3.0",
            licenceURL: "https://easylist.to/pages/licence.html",
            dns: true, browser: true, defaultEnabled: true, minRules: 20_000, expectedTitle: "EasyList", parser: .browserList),
        FilterListSource(
            id: "easyprivacy", name: "EasyPrivacy",
            summary: "Removes tracking scripts, pixels and web bugs from pages.",
            category: .privacy, urls: ["https://easylist.to/easylist/easyprivacy.txt",
                                       "https://easylist-downloads.adblockplus.org/easyprivacy.txt"],
            homepage: "https://easylist.to/", licence: "GPL-3.0 or CC BY-SA 3.0",
            licenceURL: "https://easylist.to/pages/licence.html",
            dns: true, browser: true, defaultEnabled: true, minRules: 20_000, expectedTitle: "EasyPrivacy", parser: .browserList),
    ]

    public static var defaultEnabledIDs: [String] { all.filter { $0.defaultEnabled }.map { $0.id } }

    public static func source(id: String) -> FilterListSource? { all.first { $0.id == id } }

    /// Hosts lists may be fetched from (anything else is refused, even via redirects).
    public static var allowedHosts: Set<String> {
        var s: Set<String> = []
        for l in all { for u in l.urls { if let h = URL(string: u)?.host { s.insert(h.lowercased()) } } }
        return s
    }
}
