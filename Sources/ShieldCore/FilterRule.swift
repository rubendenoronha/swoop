// SPDX-License-Identifier: MIT
import Foundation

/// How a DNS-level rule matches a hostname.
public enum HostPatternKind: UInt8, Codable, Hashable {
    /// `||example.com^`, plain-domain lists: the domain and every subdomain.
    case subtree = 0
    /// hosts files (`0.0.0.0 example.com`), `|example.com^`: that exact name only.
    case exact = 1
    /// `||ad*.example.com^`, `*.example.com`: glob over the whole hostname.
    case wildcard = 2
    /// `/^ad[0-9]+\.example\.com$/`: regular expression over the hostname.
    case regex = 3
}

public struct HostPattern: Hashable, Codable, CustomStringConvertible {
    public var kind: HostPatternKind
    public var value: String

    public init(_ kind: HostPatternKind, _ value: String) {
        self.kind = kind
        self.value = value
    }

    public var description: String {
        switch kind {
        case .subtree: return "||\(value)^"
        case .exact: return "|\(value)^"
        case .wildcard: return "||\(value)^"
        case .regex: return "/\(value)/"
        }
    }
}

/// A rule the DNS layer (system extension, local resolver) can apply.
public struct DNSRule: Hashable, Codable {
    public var pattern: HostPattern
    public var isException: Bool
    public var important: Bool
    /// `$denyallow=a.com|b.com`: the block does not apply to these domains (and subdomains).
    public var denyAllow: [String]
    /// `$dnstype=AAAA|~A`: record types the rule applies to (empty = all). Lowercased names.
    public var dnsTypes: [String]
    public var excludedDNSTypes: [String]

    public init(pattern: HostPattern, isException: Bool = false, important: Bool = false,
                denyAllow: [String] = [], dnsTypes: [String] = [], excludedDNSTypes: [String] = []) {
        self.pattern = pattern
        self.isException = isException
        self.important = important
        self.denyAllow = denyAllow
        self.dnsTypes = dnsTypes
        self.excludedDNSTypes = excludedDNSTypes
    }

    /// Needs more than a trie lookup (wildcards, regex, modifiers).
    public var isComplex: Bool {
        pattern.kind == .wildcard || pattern.kind == .regex || !denyAllow.isEmpty || !dnsTypes.isEmpty || !excludedDNSTypes.isEmpty
    }

    /// Canonical text (used for `$badfilter` and to serialise complex rules into the index).
    public var canonical: String {
        var s = (isException ? "@@" : "") + pattern.description
        var mods: [String] = []
        if important { mods.append("important") }
        if !denyAllow.isEmpty { mods.append("denyallow=" + denyAllow.joined(separator: "|")) }
        let types = dnsTypes.map { $0.uppercased() } + excludedDNSTypes.map { "~" + $0.uppercased() }
        if !types.isEmpty { mods.append("dnstype=" + types.joined(separator: "|")) }
        if !mods.isEmpty { s += "$" + mods.joined(separator: ",") }
        return s
    }

    public func applies(toType type: String?) -> Bool {
        guard let t = type?.lowercased() else { return dnsTypes.isEmpty }
        if !dnsTypes.isEmpty && !dnsTypes.contains(t) { return false }
        if excludedDNSTypes.contains(t) { return false }
        return true
    }
}

/// Request types used by the browser layers. Raw values follow ABP/uBO option names.
public enum ResourceType: String, CaseIterable, Codable, Hashable {
    case document, subdocument, stylesheet, script, image, font, media, xmlhttprequest, websocket, ping, object, other, popup
}

/// A URL-level rule for the browser layers (Safari content blockers, Chromium/Firefox
/// declarativeNetRequest).
public struct NetworkRule: Hashable, Codable {
    public var pattern: String          // ABP pattern without "@@" and "$options", or a regex source
    public var isRegex: Bool
    public var isException: Bool
    public var important: Bool
    public var matchCase: Bool
    /// true = `$third-party`, false = `$~third-party` / `$first-party`, nil = either.
    public var thirdParty: Bool?
    public var resourceTypes: Set<ResourceType>          // empty = every type except document/popup
    public var excludedResourceTypes: Set<ResourceType>
    public var includeDomains: [String]                   // `$domain=a.com|b.com`
    public var excludeDomains: [String]                   // `$domain=~c.com`
    /// `@@…$document`: allow everything on matching pages.
    public var documentException: Bool
    /// `$elemhide`/`$generichide` exceptions: switch off cosmetic filtering on matching pages.
    public var elemHideException: Bool
    public var genericHideException: Bool
    public var redirect: String?

    public init(pattern: String, isRegex: Bool = false, isException: Bool = false, important: Bool = false,
                matchCase: Bool = false, thirdParty: Bool? = nil, resourceTypes: Set<ResourceType> = [],
                excludedResourceTypes: Set<ResourceType> = [], includeDomains: [String] = [], excludeDomains: [String] = [],
                documentException: Bool = false, elemHideException: Bool = false, genericHideException: Bool = false,
                redirect: String? = nil) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.isException = isException
        self.important = important
        self.matchCase = matchCase
        self.thirdParty = thirdParty
        self.resourceTypes = resourceTypes
        self.excludedResourceTypes = excludedResourceTypes
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
        self.documentException = documentException
        self.elemHideException = elemHideException
        self.genericHideException = genericHideException
        self.redirect = redirect
    }

    /// `||host^` with nothing else: the cheapest rule shape, groupable in DNR.
    public var plainHost: String? {
        guard !isRegex, thirdParty == nil, resourceTypes.isEmpty, excludedResourceTypes.isEmpty,
              includeDomains.isEmpty, excludeDomains.isEmpty, !matchCase, redirect == nil,
              !elemHideException, !genericHideException, !documentException else { return nil }
        guard pattern.hasPrefix("||") else { return nil }
        var body = pattern.dropFirst(2)
        if body.hasSuffix("^|") { body = body.dropLast(2) } else if body.hasSuffix("^") { body = body.dropLast() } else { return nil }
        return DomainName.normalize(String(body))
    }
}

public enum CosmeticKind: String, Codable, Hashable {
    /// `##.selector`: plain CSS, hidden with display:none.
    case hide
    /// `#?#`, or `##` with procedural pseudo-classes (`:has-text()`, `:upward()`…): needs JS.
    case procedural
    /// `#$#selector { style }` (AdGuard CSS injection).
    case style
}

public struct CosmeticRule: Hashable, Codable {
    public var includeDomains: [String]   // empty = generic (every site)
    public var excludeDomains: [String]
    public var selector: String
    public var isException: Bool
    public var kind: CosmeticKind

    public init(includeDomains: [String] = [], excludeDomains: [String] = [], selector: String,
                isException: Bool = false, kind: CosmeticKind = .hide) {
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
        self.selector = selector
        self.isException = isException
        self.kind = kind
    }

    public var isGeneric: Bool { includeDomains.isEmpty }
}

public struct ScriptletRule: Hashable, Codable {
    public var includeDomains: [String]
    public var excludeDomains: [String]
    public var name: String               // normalised (uBO/ABP/AdGuard aliases folded)
    public var args: [String]
    public var isException: Bool

    public init(includeDomains: [String] = [], excludeDomains: [String] = [], name: String, args: [String] = [], isException: Bool = false) {
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
        self.name = name
        self.args = args
        self.isException = isException
    }
}

/// Everything one filter-list line produced.
public struct ParsedLine: Equatable {
    public var dns: DNSRule?
    public var network: NetworkRule?
    public var cosmetic: CosmeticRule?
    public var scriptlets: [ScriptletRule] = []
    /// `$badfilter`: the rule this line switches off (canonical DNS form and/or network rule).
    public var badfilterDNS: DNSRule?
    public var badfilterNetwork: NetworkRule?
    public var metadata: (key: String, value: String)?
    public var error: String?
    public var isComment = false

    public init() {}

    public var isEmpty: Bool {
        dns == nil && network == nil && cosmetic == nil && scriptlets.isEmpty && badfilterDNS == nil
            && badfilterNetwork == nil && metadata == nil && error == nil
    }

    public static func == (a: ParsedLine, b: ParsedLine) -> Bool {
        a.dns == b.dns && a.network == b.network && a.cosmetic == b.cosmetic && a.scriptlets == b.scriptlets
            && a.badfilterDNS == b.badfilterDNS && a.badfilterNetwork == b.badfilterNetwork
            && a.metadata?.key == b.metadata?.key && a.metadata?.value == b.metadata?.value
            && a.error == b.error && a.isComment == b.isComment
    }
}
