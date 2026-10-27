// SPDX-License-Identifier: MIT
//
// Turns downloaded list texts into everything Shield runs on: the binary DNS index, Safari
// content-blocker chunks, declarativeNetRequest rulesets and the cosmetic bundle. Used by
// the app (daily, on the Mac) and by `swoop-shield-compile` (CI, developers).
import Foundation

public struct ListText {
    public var source: FilterListSource
    public var text: String
    public init(source: FilterListSource, text: String) { self.source = source; self.text = text }
}

public struct CompileReport: Codable, Equatable {
    public struct PerList: Codable, Equatable {
        public var id: String
        public var lines = 0
        public var dnsRules = 0
        public var networkRules = 0
        public var cosmeticRules = 0
        public var scriptlets = 0
        public var errors = 0
    }
    public var lists: [PerList] = []
    public var dnsDomains = 0
    public var dnsComplex = 0
    public var indexBytes = 0
    public var safariRules = 0
    public var safariDropped = 0
    public var dnrRules = 0
    public var cosmeticSelectors = 0
    public var skipped: [String: Int] = [:]
    public var seconds = 0.0
}

public struct CompiledShield {
    public var index: Data
    public var safari: SafariConversion?
    public var dnr: DNRConversion?
    public var cosmetic: CosmeticBundle?
    public var report: CompileReport
}

public enum ShieldCompiler {
    /// Rules that ship with Swoop (MIT): YouTube in-page ad handling and a few extras the
    /// public lists leave to uBO-specific filters. Applied by the browser layers only.
    public static let builtInBrowserRules = """
    ! Title: Swoop Shield built-in rules
    ! License: MIT (part of Swoop)
    ! YouTube: strip ad placements from the player response (best effort; YouTube changes often).
    youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune, playerResponse.adPlacements playerResponse.playerAds playerResponse.adSlots adPlacements playerAds adSlots)
    youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune-fetch-response, playerAds adPlacements adSlots playerResponse.playerAds playerResponse.adPlacements playerResponse.adSlots, , propsToMatch, /\\/(player|get_watch)\\?/)
    youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune-xhr-response, playerAds adPlacements adSlots playerResponse.playerAds playerResponse.adPlacements playerResponse.adSlots, , propsToMatch, /\\/player\\?/)
    youtube.com,youtubekids.com##+js(set-constant, ytInitialPlayerResponse.playerAds, undefined)
    youtube.com,youtubekids.com##+js(set-constant, ytInitialPlayerResponse.adPlacements, undefined)
    youtube.com,youtubekids.com##+js(set-constant, ytInitialPlayerResponse.adSlots, undefined)
    youtube.com,youtubekids.com##+js(set-constant, playerResponse.adPlacements, undefined)
    youtube.com##ytd-ad-slot-renderer
    youtube.com##ytd-in-feed-ad-layout-renderer
    youtube.com##ytd-promoted-sparkles-web-renderer
    youtube.com##ytd-promoted-video-renderer
    youtube.com##ytd-display-ad-renderer
    youtube.com##ytd-banner-promo-renderer
    youtube.com##ytd-statement-banner-renderer
    youtube.com##ytd-player-legacy-desktop-watch-ads-renderer
    youtube.com##ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"]
    youtube.com###masthead-ad
    youtube.com###player-ads
    youtube.com##.ytp-ad-module
    youtube.com##.ytp-ad-overlay-container
    youtube.com##.ytd-merch-shelf-renderer
    youtube.com##ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)
    youtube.com##ytd-rich-section-renderer:has(ytd-statement-banner-renderer)
    m.youtube.com##ad-slot-renderer
    m.youtube.com##ytm-promoted-sparkles-web-renderer
    m.youtube.com##.ytm-companion-ad-renderer
    ! YouTube ad/telemetry endpoints that are safe to block at request level.
    ||youtube.com/pagead/
    ||youtube.com/api/stats/ads
    ||youtube.com/get_midroll_
    ||doubleclick.net^$third-party
    ||googlesyndication.com^$third-party
    ! Pax (paxpeace.com, accountability blocker): Swoop never blocks its site or servers.
    @@||paxpeace.com^$important
    """

    public static let builtInSource = FilterListSource(
        id: "swoop-builtin", name: "Swoop built-in", summary: "YouTube and in-page ad handling that ships with Swoop.",
        category: .ads, urls: [], homepage: "https://swoopkey.com", licence: "MIT", licenceURL: "https://swoopkey.com",
        dns: false, browser: true, defaultEnabled: true, minRules: 0, expectedTitle: nil, parser: .browserList)

    public struct Options {
        public var buildBrowser: Bool
        public var safariChunkSize: Int
        public var safariChunkCount: Int
        public var dnrRulesPerRuleset: Int
        public var includeBuiltInBrowserRules: Bool
        public init(buildBrowser: Bool = true, safariChunkSize: Int = SafariConverter.defaultChunkSize,
                    safariChunkCount: Int = SafariConverter.defaultChunkCount, dnrRulesPerRuleset: Int = DNRConverter.guaranteedStaticRules,
                    includeBuiltInBrowserRules: Bool = true) {
            self.buildBrowser = buildBrowser
            self.safariChunkSize = safariChunkSize
            self.safariChunkCount = safariChunkCount
            self.dnrRulesPerRuleset = dnrRulesPerRuleset
            self.includeBuiltInBrowserRules = includeBuiltInBrowserRules
        }
    }

    public static func compile(_ lists: [ListText], options: Options = Options(), now: Date = Date()) throws -> CompiledShield {
        let start = Date()
        var report = CompileReport()
        var builder = DomainIndexBuilder()
        var network: [NetworkRule] = [], cosmetic: [CosmeticRule] = [], scriptlets: [ScriptletRule] = []
        var badNetwork: Set<NetworkRule> = []
        var seenNetwork: Set<NetworkRule> = []

        var all = lists
        if options.buildBrowser && options.includeBuiltInBrowserRules {
            all.append(ListText(source: builtInSource, text: builtInBrowserRules))
        }
        for l in all {
            var per = CompileReport.PerList(id: l.source.id)
            let si = l.source.dns ? try builder.source(l.source.id) : 0
            let opts = RuleParserOptions(plainDomainIsSubtree: l.source.parserOptions.plainDomainIsSubtree,
                                         regexIsHostname: l.source.parserOptions.regexIsHostname,
                                         keepCosmetic: options.buildBrowser && l.source.browser)
            l.text.enumerateLines { line, _ in
                per.lines += 1
                if l.source.dns, let hosts = RuleParser.hostsEntries(line) {
                    for h in hosts { builder.add(h, sourceIndex: si); per.dnsRules += 1 }
                    return
                }
                let p = RuleParser.parseLine(line, options: opts)
                if p.error != nil { per.errors += 1 }
                if l.source.dns {
                    if let d = p.dns { builder.add(d, sourceIndex: si); per.dnsRules += 1 }
                    if let b = p.badfilterDNS { builder.disable(b) }
                }
                guard options.buildBrowser && l.source.browser else { return }
                if let n = p.network, seenNetwork.insert(n).inserted { network.append(n); per.networkRules += 1 }
                if let b = p.badfilterNetwork { badNetwork.insert(b) }
                if let c = p.cosmetic { cosmetic.append(c); per.cosmeticRules += 1 }
                if !p.scriptlets.isEmpty { scriptlets += p.scriptlets; per.scriptlets += p.scriptlets.count }
            }
            report.lists.append(per)
        }
        if !badNetwork.isEmpty { network.removeAll { badNetwork.contains($0) } }
        let index = builder.build(createdAt: now)
        report.dnsDomains = builder.domainCount
        report.dnsComplex = builder.complexCount
        report.indexBytes = index.count

        var result = CompiledShield(index: index, safari: nil, dnr: nil, cosmetic: nil, report: report)
        if options.buildBrowser {
            let safari = SafariConverter.convert(network: network, cosmetic: cosmetic, chunkSize: options.safariChunkSize,
                                                 chunkCount: options.safariChunkCount)
            let dnr = DNRConverter.convert(network: network, rulesPerRuleset: options.dnrRulesPerRuleset)
            let (bundle, cskip) = CosmeticCompiler.compile(cosmetic: cosmetic, scriptlets: scriptlets, network: network)
            result.safari = safari
            result.dnr = dnr
            result.cosmetic = bundle
            report.safariRules = safari.totalRules
            report.safariDropped = safari.dropped
            report.dnrRules = dnr.totalRules
            report.cosmeticSelectors = bundle.selectorCount
            for (k, v) in safari.skipped { report.skipped["safari: " + k, default: 0] += v }
            for (k, v) in dnr.skipped { report.skipped["dnr: " + k, default: 0] += v }
            for (k, v) in cskip { report.skipped["cosmetic: " + k, default: 0] += v }
        }
        report.seconds = Date().timeIntervalSince(start)
        result.report = report
        return result
    }
}

/// Fallback without the system extension: a configuration profile that switches macOS to an
/// encrypted DNS server. Honest trade-off: the server's own filtering applies, not Swoop's
/// lists, stats or allowlist (unless the server is Swoop's local resolver).
public enum DNSProfileBuilder {
    public struct Provider: Equatable {
        public var id: String
        public var name: String
        public var url: String
        public var addresses: [String]
        public var note: String
    }

    public static let providers: [Provider] = [
        Provider(id: "adguard", name: "AdGuard DNS (ads + trackers)", url: "https://dns.adguard-dns.com/dns-query",
                 addresses: ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"],
                 note: "Free public resolver run by AdGuard (Cyprus). Blocks ads and trackers with AdGuard's own lists."),
        Provider(id: "mullvad-adblock", name: "Mullvad DNS (ads + trackers)", url: "https://adblock.dns.mullvad.net/dns-query",
                 addresses: ["194.242.2.3"], note: "Free, no-logging resolver run by Mullvad VPN (Sweden)."),
        Provider(id: "quad9", name: "Quad9 (malware only)", url: "https://dns.quad9.net/dns-query",
                 addresses: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"],
                 note: "Non-profit resolver (Switzerland). Blocks malware and phishing, not ads."),
    ]

    /// A .mobileconfig with a com.apple.dnsSettings.managed payload (macOS 11+).
    public static func profile(name: String, url: String, addresses: [String], identifier: String = "com.swoopkey.swoop.shield.dns",
                               uuid: String = UUID().uuidString, payloadUUID: String = UUID().uuidString) -> String {
        func x(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let addrs = addresses.map { "          <string>\(x($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadContent</key>
          <array>
            <dict>
              <key>DNSSettings</key>
              <dict>
                <key>DNSProtocol</key><string>HTTPS</string>
                <key>ServerURL</key><string>\(x(url))</string>
                <key>ServerAddresses</key>
                <array>
        \(addrs)
                </array>
              </dict>
              <key>PayloadDisplayName</key><string>\(x(name))</string>
              <key>PayloadIdentifier</key><string>\(identifier).settings</string>
              <key>PayloadType</key><string>com.apple.dnsSettings.managed</string>
              <key>PayloadUUID</key><string>\(payloadUUID)</string>
              <key>PayloadVersion</key><integer>1</integer>
              <key>ProhibitDisablement</key><false/>
            </dict>
          </array>
          <key>PayloadDescription</key><string>Encrypted DNS set up by Swoop Shield. Remove it any time in System Settings › Privacy &amp; Security › Profiles (macOS 13–14: System Settings › Profiles).</string>
          <key>PayloadDisplayName</key><string>Swoop Shield: \(x(name))</string>
          <key>PayloadIdentifier</key><string>\(identifier)</string>
          <key>PayloadOrganization</key><string>Swoop</string>
          <key>PayloadRemovalDisallowed</key><false/>
          <key>PayloadScope</key><string>System</string>
          <key>PayloadType</key><string>Configuration</string>
          <key>PayloadUUID</key><string>\(uuid)</string>
          <key>PayloadVersion</key><integer>1</integer>
        </dict>
        </plist>
        """
    }
}
