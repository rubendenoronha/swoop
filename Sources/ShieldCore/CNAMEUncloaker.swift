// SPDX-License-Identifier: MIT
//
// CNAME cloaking: a site points a first-party name (metrics.example.com) at a tracker
// (example.eulerian.net) so blockers that only look at the name you asked for miss it.
// Shield checks every name in the answer's CNAME / HTTPS-alias chain against the same
// rules, and blocks the original lookup when a cloaked tracker is found.
import Foundation

public struct UncloakResult: Equatable {
    public enum Verdict: Equatable { case pass, blocked(MatchInfo) }
    public var verdict: Verdict
    /// The chain that was examined (for the query log).
    public var chain: [String]
    /// The chain was cut short (loop or longer than the limit).
    public var truncated: Bool

    public var isBlocked: Bool { if case .blocked = verdict { return true }; return false }
}

public struct CNAMEUncloaker {
    /// Well-known CNAME-cloaking tracker domains (first-party "disguised" analytics). A
    /// compact built-in subset; the full AdGuard cname-trackers list (MIT) is an optional
    /// filter list in the catalog. Applied only when the target belongs to a different
    /// registrable domain than the name asked for.
    public static let builtInCloakingTrackers: [String] = [
        "eulerian.net", "at-o.net", "xiti.com", "omtrdc.net", "2o7.net", "adobedc.net", "keyade.com", "wizaly.com",
        "dnsdelegation.io", "storetail.io", "tagcommander.com", "commander1.com", "affex.org", "oghub.io",
        "tracedock.com", "ingenious.cloud", "webtrekk.net", "wt-eu02.net", "dataunlocker.com",
    ]

    public var maxChainLength: Int
    public var useBuiltInTrackers: Bool
    private let trackers: Set<String>

    public init(maxChainLength: Int = 16, useBuiltInTrackers: Bool = true, extraTrackers: [String] = []) {
        self.maxChainLength = maxChainLength
        self.useBuiltInTrackers = useBuiltInTrackers
        var t = Set(CNAMEUncloaker.builtInCloakingTrackers.compactMap { DomainName.normalize($0) })
        for e in extraTrackers { if let n = DomainName.normalize(e) { t.insert(n) } }
        trackers = t
    }

    /// `queryResult` is what the rules said about the name asked for. `matcher` checks each
    /// alias. An explicit allow for the original name (allowlist, exception) always wins.
    public func evaluate(query: String, queryResult: MatchResult, chain rawChain: [String],
                         matcher: (String) -> MatchResult) -> UncloakResult {
        var seen: Set<String> = [query.lowercased()]
        var chain: [String] = []
        var truncated = false
        for n in rawChain {
            let name = n.lowercased()
            if !seen.insert(name).inserted { truncated = true; break }
            if chain.count >= maxChainLength { truncated = true; break }
            chain.append(name)
        }
        if case .allowed = queryResult { return UncloakResult(verdict: .pass, chain: chain, truncated: truncated) }
        if case .blocked(let info) = queryResult { return UncloakResult(verdict: .blocked(info), chain: chain, truncated: truncated) }

        let querySite = DomainName.registrableDomain(query)
        for target in chain {
            switch matcher(target) {
            case .blocked(let info):
                return UncloakResult(verdict: .blocked(MatchInfo(source: info.source, rule: info.rule, cnameTarget: target)),
                                     chain: chain, truncated: truncated)
            case .allowed:
                // An exception for the alias (e.g. a CDN the lists allow) ends the walk.
                return UncloakResult(verdict: .pass, chain: chain, truncated: truncated)
            case .noMatch:
                if useBuiltInTrackers, DomainName.registrableDomain(target) != querySite,
                   let hit = DomainName.suffixes(target).first(where: { trackers.contains(String($0)) }) {
                    return UncloakResult(verdict: .blocked(MatchInfo(source: "cname", rule: "||\(hit)^", cnameTarget: target)),
                                         chain: chain, truncated: truncated)
                }
            }
        }
        return UncloakResult(verdict: .pass, chain: chain, truncated: truncated)
    }
}
