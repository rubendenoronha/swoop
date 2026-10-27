// SPDX-License-Identifier: MIT
//
// Rules for the Manifest V3 WebExtension (Chrome, Arc, Brave, Edge, Vivaldi, Opera,
// Firefox 128+) and the cosmetic/scriptlet data its content scripts use (also used by the
// Safari Web Extension).
//
// declarativeNetRequest notes:
//   • Plain "||host^" blocks are grouped into rules with `requestDomains` (thousands of hosts
//     per rule), so a 60k-rule list fits easily under the 30,000 guaranteed static rules.
//   • Priorities: block 1 < allow 2 < allowAllRequests 3 < important block 4 < important allow 5.
//   • At most 1,000 regex rules (RE2 syntax; lookarounds/backreferences skipped).
//   • Rulesets are capped at `rulesPerRuleset` rules each.
import Foundation

public struct DNRRule: Codable, Equatable {
    public struct Action: Codable, Equatable {
        public var type: String   // block | allow | allowAllRequests
    }
    public struct Condition: Codable, Equatable {
        public var urlFilter: String?
        public var regexFilter: String?
        public var isUrlFilterCaseSensitive: Bool?
        public var requestDomains: [String]?
        public var initiatorDomains: [String]?
        public var excludedInitiatorDomains: [String]?
        public var domainType: String?
        public var resourceTypes: [String]?
        public var excludedResourceTypes: [String]?
    }
    public var id: Int
    public var priority: Int
    public var action: Action
    public var condition: Condition
}

public struct DNRRuleset: Equatable {
    public var id: String
    public var rules: [DNRRule]
}

public struct DNRConversion {
    public var rulesets: [DNRRuleset]
    public var skipped: [String: Int] = [:]
    public var regexCount = 0
    public var totalRules: Int { rulesets.reduce(0) { $0 + $1.rules.count } }
}

public enum DNRConverter {
    public static let maxRegexRules = 1000
    public static let guaranteedStaticRules = 30_000
    static let domainsPerRule = 1000

    static let typeMap: [ResourceType: String] = [
        .document: "main_frame", .subdocument: "sub_frame", .stylesheet: "stylesheet", .script: "script", .image: "image",
        .font: "font", .media: "media", .xmlhttprequest: "xmlhttprequest", .websocket: "websocket", .ping: "ping",
        .object: "object", .other: "other",
    ]

    public static func convert(network: [NetworkRule], rulesPerRuleset: Int = guaranteedStaticRules, idPrefix: String = "swoop") -> DNRConversion {
        var res = DNRConversion(rulesets: [])
        var rules: [DNRRule] = []
        var nextID = 1
        func skip(_ why: String) { res.skipped[why, default: 0] += 1 }
        func add(_ priority: Int, _ type: String, _ c: DNRRule.Condition) {
            rules.append(DNRRule(id: nextID, priority: priority, action: .init(type: type), condition: c))
            nextID += 1
        }

        var plainBlocks: [String] = [], plainAllows: [String] = []
        var impBlocks: [String] = [], impAllows: [String] = []
        for r in network {
            if r.genericHideException || r.elemHideException { continue }   // content script handles these
            if let h = r.plainHost {
                if r.isException { if r.important { impAllows.append(h) } else { plainAllows.append(h) } }
                else { if r.important { impBlocks.append(h) } else { plainBlocks.append(h) } }
                continue
            }
            if r.resourceTypes == [.popup] { skip("popup"); continue }
            var c = DNRRule.Condition()
            if r.isRegex {
                guard res.regexCount < maxRegexRules else { skip("regex limit"); continue }
                guard isRE2Compatible(r.pattern) else { skip("regex not RE2-compatible"); continue }
                c.regexFilter = r.pattern
                res.regexCount += 1
            } else {
                guard r.pattern.unicodeScalars.allSatisfy({ $0.isASCII }) else { skip("non-ASCII pattern"); continue }
                guard !r.pattern.hasPrefix("||*") else { skip("pattern starts with ||*"); continue }
                var body = Substring(r.pattern)
                if body.hasPrefix("||") { body = body.dropFirst(2) } else if body.hasPrefix("|") { body = body.dropFirst() }
                if body.hasSuffix("|") { body = body.dropLast() }
                guard !body.contains("|") else { skip("'|' inside pattern"); continue }
                if r.pattern != "*" { c.urlFilter = r.pattern }
            }
            if r.matchCase { c.isUrlFilterCaseSensitive = true }
            if let tp = r.thirdParty { c.domainType = tp ? "thirdParty" : "firstParty" }
            if !r.includeDomains.isEmpty {
                let d = r.includeDomains.filter { !$0.hasSuffix(".*") }
                if d.isEmpty { skip("entity domain (example.*)"); continue }
                c.initiatorDomains = d
            }
            if !r.excludeDomains.isEmpty { c.excludedInitiatorDomains = r.excludeDomains.filter { !$0.hasSuffix(".*") } }
            if !r.resourceTypes.isEmpty {
                let t = r.resourceTypes.compactMap { typeMap[$0] }
                if t.isEmpty { skip("no DNR resource type"); continue }
                c.resourceTypes = t.sorted()
            }
            if !r.excludedResourceTypes.isEmpty { c.excludedResourceTypes = r.excludedResourceTypes.compactMap { typeMap[$0] }.sorted() }
            if c.urlFilter == nil && c.regexFilter == nil && c.initiatorDomains == nil && !r.documentException {
                skip("matches everything"); continue
            }
            if r.isException {
                if r.documentException {
                    var d = DNRRule.Condition()
                    if let h = r.plainHostLike { d.requestDomains = [h] } else { d.urlFilter = c.urlFilter; d.regexFilter = c.regexFilter }
                    d.resourceTypes = ["main_frame", "sub_frame"]
                    add(3, "allowAllRequests", d)
                } else {
                    add(r.important ? 5 : 2, "allow", c)
                }
            } else {
                add(r.important ? 4 : 1, "block", c)
            }
        }
        func grouped(_ hosts: [String], _ priority: Int, _ type: String) {
            let uniq = Array(Set(hosts)).sorted()
            for i in stride(from: 0, to: uniq.count, by: domainsPerRule) {
                var c = DNRRule.Condition()
                c.requestDomains = Array(uniq[i..<min(uniq.count, i + domainsPerRule)])
                add(priority, type, c)
            }
        }
        grouped(plainBlocks, 1, "block")
        grouped(plainAllows, 2, "allow")
        grouped(impBlocks, 4, "block")
        grouped(impAllows, 5, "allow")

        let size = max(1, rulesPerRuleset)
        var n = 1
        for i in stride(from: 0, to: rules.count, by: size) {
            res.rulesets.append(DNRRuleset(id: "\(idPrefix)_\(n)", rules: Array(rules[i..<min(rules.count, i + size)])))
            n += 1
        }
        return res
    }

    /// RE2 has no lookarounds or backreferences.
    static func isRE2Compatible(_ s: String) -> Bool {
        if s.contains("(?=") || s.contains("(?!") || s.contains("(?<=") || s.contains("(?<!") { return false }
        var prev: Character = " "
        for c in s {
            if prev == "\\" && c.isNumber && c != "0" { return false }
            prev = c
        }
        return s.unicodeScalars.allSatisfy { $0.isASCII }
    }

    public static func json(_ rules: [DNRRule]) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(rules)) ?? Data("[]".utf8)
    }
}

/// Cosmetic + scriptlet data for the content scripts (cosmetic.json).
public struct CosmeticBundle: Codable, Equatable {
    /// Generic `##.class` / `###id` selectors, applied only when that class/id appears in the
    /// page (uBO-style lazy generic filtering).
    public var genericClasses: [String: [String]] = [:]   // class → selectors
    public var genericIds: [String: [String]] = [:]       // id → selectors
    /// Other generic selectors, always injected.
    public var genericComplex: [String] = []
    /// Site-specific selectors by domain (subdomains inherit).
    public var specific: [String: [String]] = [:]
    /// Selectors switched off per domain (`#@#`).
    public var exceptions: [String: [String]] = [:]
    /// Procedural selectors by domain ("*" = generic).
    public var procedural: [String: [String]] = [:]
    /// `#$#` CSS injection by domain.
    public var styles: [String: [String]] = [:]
    /// Scriptlets by domain: [[name, args…]].
    public var scriptlets: [String: [[String]]] = [:]
    public var scriptletExceptions: [String: [String]] = [:]
    /// Domains with generic cosmetic filtering off (`$generichide`) or all cosmetic off (`$elemhide`/`$document`).
    public var genericHide: [String] = []
    public var elemHide: [String] = []

    public var selectorCount: Int {
        genericClasses.values.reduce(0) { $0 + $1.count } + genericIds.values.reduce(0) { $0 + $1.count } + genericComplex.count
            + specific.values.reduce(0) { $0 + $1.count } + procedural.values.reduce(0) { $0 + $1.count }
    }
    public var scriptletCount: Int { scriptlets.values.reduce(0) { $0 + $1.count } }

    public func json() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }
}

public enum CosmeticCompiler {
    public static func compile(cosmetic: [CosmeticRule], scriptlets: [ScriptletRule], network: [NetworkRule]) -> (CosmeticBundle, [String: Int]) {
        var b = CosmeticBundle()
        var skipped: [String: Int] = [:]
        var genericExcepted: Set<String> = []
        for c in cosmetic where c.isException {
            if c.includeDomains.isEmpty { genericExcepted.insert(c.selector); continue }
            for d in c.includeDomains { b.exceptions[d, default: []].append(c.selector) }
        }
        for c in cosmetic where !c.isException {
            let sel = c.selector
            switch c.kind {
            case .procedural:
                for d in c.includeDomains.isEmpty ? ["*"] : c.includeDomains { b.procedural[d, default: []].append(sel) }
            case .style:
                for d in c.includeDomains.isEmpty ? ["*"] : c.includeDomains { b.styles[d, default: []].append(sel) }
            case .hide:
                if c.isGeneric {
                    if genericExcepted.contains(sel) { continue }
                    for d in c.excludeDomains { b.exceptions[d, default: []].append(sel) }
                    if let cls = simpleToken(sel, prefix: ".") { b.genericClasses[cls, default: []].append(sel) }
                    else if let id = simpleToken(sel, prefix: "#") { b.genericIds[id, default: []].append(sel) }
                    else { b.genericComplex.append(sel) }
                } else {
                    for d in c.includeDomains { b.specific[d, default: []].append(sel) }
                    for d in c.excludeDomains { b.exceptions[d, default: []].append(sel) }
                }
            }
        }
        for s in scriptlets {
            if s.isException {
                for d in s.includeDomains.isEmpty ? ["*"] : s.includeDomains { b.scriptletExceptions[d, default: []].append(s.name) }
                continue
            }
            guard Scriptlets.isImplemented(s.name) else { skipped["scriptlet \(s.name)", default: 0] += 1; continue }
            guard !s.includeDomains.isEmpty else { skipped["generic scriptlet", default: 0] += 1; continue }
            for d in s.includeDomains { b.scriptlets[d, default: []].append([s.name] + s.args) }
            for d in s.excludeDomains { b.scriptletExceptions[d, default: []].append(s.name) }
        }
        for r in network where r.isException {
            let domains = r.includeDomains.isEmpty ? (r.plainHostLike.map { [$0] } ?? []) : r.includeDomains
            if r.genericHideException { b.genericHide += domains }
            if r.elemHideException || r.documentException { b.elemHide += domains }
        }
        b.genericHide = Array(Set(b.genericHide)).sorted()
        b.elemHide = Array(Set(b.elemHide)).sorted()
        return (b, skipped)
    }

    /// ".ad-banner" → "ad-banner"; "#ad" → "ad"; nil for anything more complex.
    static func simpleToken(_ sel: String, prefix: Character) -> String? {
        guard sel.first == prefix, sel.count > 1 else { return nil }
        let body = sel.dropFirst()
        guard body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return String(body)
    }
}
