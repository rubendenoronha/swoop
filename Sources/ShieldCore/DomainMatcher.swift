// SPDX-License-Identifier: MIT
import Foundation

/// Why a name was blocked or allowed. Shown in the query log and "top blocked" lists.
public struct MatchInfo: Equatable, Codable {
    /// "allowlist", "custom", a list id ("hagezi-pro"), "doh-policy", "cname".
    public var source: String
    /// The rule in filter syntax ("||doubleclick.net^", "@@||example.com^").
    public var rule: String
    /// For CNAME uncloaking: the cloaked tracker name that matched.
    public var cnameTarget: String?

    public init(source: String, rule: String, cnameTarget: String? = nil) {
        self.source = source
        self.rule = rule
        self.cnameTarget = cnameTarget
    }
}

public enum MatchResult: Equatable {
    case blocked(MatchInfo)
    case allowed(MatchInfo)
    case noMatch

    public var isBlocked: Bool { if case .blocked = self { return true }; return false }
    public var isAllowed: Bool { if case .allowed = self { return true }; return false }
    public var info: MatchInfo? {
        switch self {
        case .blocked(let i), .allowed(let i): return i
        case .noMatch: return nil
        }
    }
}

/// The user's own rules: the Shield allowlist (always wins) and custom rules typed in
/// Adblock/hosts syntax. Compiled into a small in-memory index on every edit, so the big
/// list index never has to be rebuilt for a user change.
public struct UserRules: Equatable {
    public var allowlist: [String]
    public var customRules: String

    public init(allowlist: [String] = [], customRules: String = "") {
        self.allowlist = allowlist
        self.customRules = customRules
    }

    /// Per-line problems in `customRules` (1-based line numbers) for the editor.
    public func problems() -> [(line: Int, message: String)] {
        var out: [(Int, String)] = []
        for (i, line) in customRules.components(separatedBy: .newlines).enumerated() {
            let r = RuleParser.parseLine(line, options: .userRules)
            if let e = r.error { out.append((i + 1, e)) }
        }
        return out
    }
}

/// Decides block / allow for a hostname. Precedence, highest first:
///   1. the Shield allowlist (user)            → allowed
///   2. custom rules: exceptions, then blocks  → allowed / blocked
///   3. list rules: $important exception > $important block > exception > block
public final class DomainMatcher {
    public let lists: ShieldIndex?
    private let allow: ShieldIndex?
    private let custom: ShieldIndex?

    public init(lists: ShieldIndex?, user: UserRules = UserRules()) {
        self.lists = lists
        var ab = DomainIndexBuilder()
        for d in user.allowlist {
            if let n = DomainName.host(fromURLOrHost: d) ?? DomainName.normalize(d, stripWildcard: true) {
                try? ab.add(DNSRule(pattern: HostPattern(.subtree, n), isException: true), source: "allowlist")
            }
        }
        allow = ab.domainCount > 0 ? try? ShieldIndex(data: ab.build(), verifyChecksum: false) : nil
        var cb = DomainIndexBuilder()
        _ = try? cb.source("custom")
        for line in user.customRules.components(separatedBy: .newlines) {
            if let hosts = RuleParser.hostsEntries(line), !hosts.isEmpty {
                for h in hosts { cb.add(h, sourceIndex: 0) }
                continue
            }
            let r = RuleParser.parseLine(line, options: .userRules)
            if let d = r.dns { cb.add(d, sourceIndex: 0) }
            if let b = r.badfilterDNS { cb.disable(b) }
        }
        custom = (cb.domainCount + cb.complexCount) > 0 ? try? ShieldIndex(data: cb.build(), verifyChecksum: false) : nil
    }

    public func match(_ rawName: String, type: String? = nil) -> MatchResult {
        guard let name = DomainName.normalize(rawName) else { return .noMatch }

        if let a = allow {
            let m = a.lookup(name)
            if m.flags.allows { return .allowed(MatchInfo(source: "allowlist", rule: m.allowRule ?? "@@||\(name)^")) }
        }
        if let c = custom {
            let m = c.lookup(name)
            let cx = c.complexMatches(name, type: type)
            if m.flags.allows { return .allowed(MatchInfo(source: "custom", rule: m.allowRule ?? "")) }
            if let e = cx.first(where: { $0.rule.isException }) { return .allowed(MatchInfo(source: "custom", rule: e.rule.canonical)) }
            if m.flags.blocks { return .blocked(MatchInfo(source: "custom", rule: m.blockRule ?? "")) }
            if let b = cx.first(where: { !$0.rule.isException }) { return .blocked(MatchInfo(source: "custom", rule: b.rule.canonical)) }
        }
        guard let l = lists else { return .noMatch }
        let m = l.lookup(name)
        let cx = l.complexMatches(name, type: type)

        let impAllowTrie = m.flags.allows && m.flags.contains(.importantAllow)
        let impAllowCx = cx.first { $0.rule.isException && $0.rule.important }
        let impBlockTrie = m.flags.blocks && m.flags.contains(.importantBlock)
        let impBlockCx = cx.first { !$0.rule.isException && $0.rule.important }
        if impAllowTrie { return .allowed(MatchInfo(source: m.allowSource ?? "lists", rule: (m.allowRule ?? "") + "$important")) }
        if let e = impAllowCx { return .allowed(MatchInfo(source: e.source, rule: e.rule.canonical)) }
        if impBlockTrie { return .blocked(MatchInfo(source: m.blockSource ?? "lists", rule: (m.blockRule ?? "") + "$important")) }
        if let b = impBlockCx { return .blocked(MatchInfo(source: b.source, rule: b.rule.canonical)) }
        if m.flags.allows { return .allowed(MatchInfo(source: m.allowSource ?? "lists", rule: m.allowRule ?? "")) }
        if let e = cx.first(where: { $0.rule.isException }) { return .allowed(MatchInfo(source: e.source, rule: e.rule.canonical)) }
        if m.flags.blocks { return .blocked(MatchInfo(source: m.blockSource ?? "lists", rule: m.blockRule ?? "")) }
        if let b = cx.first(where: { !$0.rule.isException }) { return .blocked(MatchInfo(source: b.source, rule: b.rule.canonical)) }
        return .noMatch
    }
}
