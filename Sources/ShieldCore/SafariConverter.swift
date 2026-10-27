// SPDX-License-Identifier: MIT
//
// Converts network and cosmetic rules to Safari's content-blocker JSON (WKContentRuleList)
// and splits them across Swoop's content-blocker extensions.
//
// Safari specifics handled here:
//   • url-filter is a small regex subset: no alternation "|", no {n,m}, no lookarounds,
//     no \d \w \b shorthands (converted where possible, otherwise the rule is skipped).
//   • "ignore-previous-rules" only affects rules *earlier in the same list*, so every chunk
//     carries the exceptions after its blocking and hiding rules.
//   • A list can hold at most 150,000 rules, but WebKit's compiler runs out of memory well
//     before that on real lists, so Swoop defaults to 50,000 per extension (configurable).
//   • if-domain and unless-domain can't be combined in one trigger.
import Foundation

public struct SafariRule: Codable, Equatable {
    public struct Trigger: Codable, Equatable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter", urlFilterIsCaseSensitive = "url-filter-is-case-sensitive",
                 resourceType = "resource-type", loadType = "load-type", ifDomain = "if-domain", unlessDomain = "unless-domain"
        }
    }
    public struct Action: Codable, Equatable {
        public var type: String
        public var selector: String?
    }
    public var trigger: Trigger
    public var action: Action
}

public struct SafariConversion {
    public var chunks: [[SafariRule]]
    public var blockRules = 0
    public var hideRules = 0
    public var exceptionRules = 0
    public var skipped: [String: Int] = [:]
    /// Rules that didn't fit in the available extensions.
    public var dropped = 0

    public var totalRules: Int { chunks.reduce(0) { $0 + $1.count } }
}

public enum SafariConverter {
    public static let hardLimit = 150_000
    public static let defaultChunkSize = 50_000
    public static let defaultChunkCount = 6
    static let selectorsPerRule = 250

    /// - Parameters:
    ///   - chunkSize: rules per content-blocker extension (≤ 150,000).
    ///   - chunkCount: how many content-blocker extensions the app ships.
    public static func convert(network: [NetworkRule], cosmetic: [CosmeticRule], chunkSize: Int = defaultChunkSize,
                               chunkCount: Int = defaultChunkCount) -> SafariConversion {
        var res = SafariConversion(chunks: [])
        var blocks: [SafariRule] = []
        var exceptions: [SafariRule] = []

        func skip(_ why: String) { res.skipped[why, default: 0] += 1 }

        for r in network {
            if r.redirect != nil && !r.isException { /* still block the request */ }
            if r.genericHideException || r.elemHideException {
                // Safari can't scope "ignore" to cosmetic rules only; handled by the WebExtension.
                skip("elemhide/generichide exception"); continue
            }
            if r.resourceTypes == [.popup] { skip("popup"); continue }
            guard let filter = urlFilter(for: r) else { skip(r.isRegex ? "regex not supported by Safari" : "pattern not convertible"); continue }
            var t = SafariRule.Trigger(urlFilter: filter)
            if r.matchCase { t.urlFilterIsCaseSensitive = true }
            let types = safariTypes(r)
            if let ty = types { if ty.isEmpty { skip("no Safari resource type"); continue }; t.resourceType = ty }
            if let tp = r.thirdParty { t.loadType = [tp ? "third-party" : "first-party"] }
            if !r.includeDomains.isEmpty {
                let d = r.includeDomains.compactMap(safariDomain)
                if d.isEmpty { skip("domain not convertible"); continue }
                t.ifDomain = d
            } else if !r.excludeDomains.isEmpty {
                let d = r.excludeDomains.compactMap(safariDomain)
                if !d.isEmpty { t.unlessDomain = d }
            }
            if r.isException {
                if r.documentException {
                    // Allow everything on matching pages: trigger on the page's domain.
                    if let host = r.plainHostLike {
                        t = SafariRule.Trigger(urlFilter: ".*", ifDomain: ["*" + host])
                    }
                }
                exceptions.append(SafariRule(trigger: t, action: .init(type: "ignore-previous-rules", selector: nil)))
                res.exceptionRules += 1
            } else {
                blocks.append(SafariRule(trigger: t, action: .init(type: "block", selector: nil)))
                res.blockRules += 1
            }
        }

        // Cosmetic: batch generic selectors; group domain-specific ones by domain set.
        var hides: [SafariRule] = []
        var genericSelectors: [String] = []
        var exceptedGeneric: [String: [String]] = [:]   // selector → domains where it must not apply
        var specific: [String: [String]] = [:]          // "a.com,b.com|~c.com" → selectors
        var cosmeticExceptions: [String: Set<String>] = [:]
        for c in cosmetic where c.isException && c.kind == .hide {
            for d in c.includeDomains { cosmeticExceptions[c.selector, default: []].insert(d) }
        }
        for c in cosmetic where !c.isException {
            guard c.kind == .hide else { skip("procedural/style cosmetic (WebExtension handles it)"); continue }
            guard isSafeSelector(c.selector) else { skip("selector not safe for Safari"); continue }
            if c.isGeneric {
                if let ex = cosmeticExceptions[c.selector], !ex.isEmpty {
                    exceptedGeneric[c.selector] = Array(ex).sorted() + c.excludeDomains
                } else if !c.excludeDomains.isEmpty {
                    exceptedGeneric[c.selector] = c.excludeDomains
                } else {
                    genericSelectors.append(c.selector)
                }
            } else {
                let inc = c.includeDomains.filter { !$0.hasSuffix(".*") && !(cosmeticExceptions[c.selector]?.contains($0) ?? false) }
                if inc.isEmpty { skip("entity domain (example.*)"); continue }
                specific[inc.sorted().joined(separator: ","), default: []].append(c.selector)
            }
        }
        for batch in stride(from: 0, to: genericSelectors.count, by: selectorsPerRule) {
            let sel = genericSelectors[batch..<min(genericSelectors.count, batch + selectorsPerRule)].joined(separator: ", ")
            hides.append(SafariRule(trigger: .init(urlFilter: ".*"), action: .init(type: "css-display-none", selector: sel)))
        }
        for (sel, domains) in exceptedGeneric.sorted(by: { $0.key < $1.key }) {
            let d = domains.compactMap(safariDomain)
            hides.append(SafariRule(trigger: .init(urlFilter: ".*", unlessDomain: d.isEmpty ? nil : d),
                                    action: .init(type: "css-display-none", selector: sel)))
        }
        for (key, sels) in specific.sorted(by: { $0.key < $1.key }) {
            let domains = key.split(separator: ",").compactMap { safariDomain(String($0)) }
            for batch in stride(from: 0, to: sels.count, by: selectorsPerRule) {
                let sel = sels[batch..<min(sels.count, batch + selectorsPerRule)].joined(separator: ", ")
                hides.append(SafariRule(trigger: .init(urlFilter: ".*", ifDomain: domains), action: .init(type: "css-display-none", selector: sel)))
            }
        }
        res.hideRules = hides.count

        res.chunks = split(blocking: blocks + hides, exceptions: exceptions, chunkSize: min(chunkSize, hardLimit),
                           chunkCount: chunkCount, dropped: &res.dropped)
        return res
    }

    /// Every chunk = its share of blocking/hiding rules, then *all* exceptions (so an exception
    /// can override a block that landed in any chunk). Shares are as even as the limit allows.
    public static func split(blocking: [SafariRule], exceptions: [SafariRule], chunkSize: Int, chunkCount: Int,
                             dropped: inout Int) -> [[SafariRule]] {
        guard chunkCount > 0, chunkSize > 0 else { dropped = blocking.count + exceptions.count; return [] }
        var exc = exceptions
        if exc.count > chunkSize / 2 {
            dropped += exc.count - chunkSize / 2
            exc = Array(exc.prefix(chunkSize / 2))
        }
        // Spread rules evenly over the available blockers: WebKit compiles each list in a
        // memory-limited process, so six medium lists are safer than two full ones.
        let even = max(1, (blocking.count + chunkCount - 1) / chunkCount)
        let room = max(1, min(chunkSize - exc.count, even))
        var chunks: [[SafariRule]] = []
        var i = 0
        while i < blocking.count && chunks.count < chunkCount {
            let end = min(blocking.count, i + room)
            chunks.append(Array(blocking[i..<end]) + exc)
            i = end
        }
        if i < blocking.count { dropped += blocking.count - i }
        if chunks.isEmpty && !exc.isEmpty { chunks.append(exc) }
        // Safari rejects an empty list; give unused extensions a harmless no-op rule.
        while chunks.count < chunkCount {
            chunks.append([SafariRule(trigger: .init(urlFilter: "^swoop-shield-unused:"), action: .init(type: "block", selector: nil))])
        }
        return chunks
    }

    public static func json(_ rules: [SafariRule]) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(rules)) ?? Data("[]".utf8)
    }

    // MARK: pieces

    static func safariDomain(_ d: String) -> String? {
        guard !d.hasSuffix(".*"), d.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        return "*" + d   // "*" = the domain and its subdomains
    }

    /// nil = every type (no resource-type key); [] = nothing convertible.
    static func safariTypes(_ r: NetworkRule) -> [String]? {
        let map: [ResourceType: String] = [
            .document: "document", .subdocument: "document", .stylesheet: "style-sheet", .script: "script", .image: "image",
            .font: "font", .media: "media", .xmlhttprequest: "raw", .websocket: "raw", .ping: "raw", .object: "raw",
            .other: "raw", .popup: "popup",
        ]
        if r.resourceTypes.isEmpty && r.excludedResourceTypes.isEmpty { return nil }
        var types: Set<ResourceType> = r.resourceTypes.isEmpty
            ? Set(ResourceType.allCases).subtracting([.document, .popup]) : r.resourceTypes
        types.subtract(r.excludedResourceTypes)
        let out = Set(types.compactMap { map[$0] })
        return out.sorted()
    }

    static let regexSpecial: Set<Character> = [".", "+", "?", "$", "{", "}", "(", ")", "[", "]", "\\", "/"]

    /// ABP pattern → Safari url-filter.
    public static func urlFilter(for r: NetworkRule) -> String? {
        if r.isRegex { return safariRegex(r.pattern) }
        var p = Substring(r.pattern)
        guard p.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        if p == "*" || p.isEmpty { return ".*" }
        var out = ""
        if p.hasPrefix("||") {
            out = "^[htpsw]+:\\/\\/([a-z0-9_-]+\\.)*"
            p = p.dropFirst(2)
        } else if p.hasPrefix("|") {
            out = "^"
            p = p.dropFirst()
        }
        var endAnchor = false
        if p.hasSuffix("|") { endAnchor = true; p = p.dropLast() }
        while p.hasPrefix("*") { p = p.dropFirst() }
        while p.hasSuffix("*") { p = p.dropLast() }
        for c in p {
            switch c {
            case "*": out += ".*"
            case "^": out += "[/:?=&]"
            case "|": return nil
            default:
                if regexSpecial.contains(c) { out += "\\" + String(c) } else { out.append(c) }
            }
        }
        if endAnchor {
            if out.hasSuffix("[/:?=&]") { out.removeLast("[/:?=&]".count) }
            out += "$"
        }
        return out.isEmpty ? ".*" : out
    }

    /// Accepts a regex only if Safari's subset can express it.
    static func safariRegex(_ src: String) -> String? {
        var out = ""
        var inClass = false
        var it = src.makeIterator()
        while let c = it.next() {
            if c == "\\" {
                guard let n = it.next() else { return nil }
                switch n {
                case "d": out += inClass ? "0-9" : "[0-9]"
                case "w": out += inClass ? "a-zA-Z0-9_" : "[a-zA-Z0-9_]"
                case "D", "W", "s", "S", "b", "B", "1", "2", "3", "4", "5", "6", "7", "8", "9": return nil
                default: out += "\\" + String(n)
                }
                continue
            }
            if c == "[" { inClass = true } else if c == "]" { inClass = false }
            if !inClass && (c == "|" || c == "{" || c == "}") { return nil }
            out.append(c)
        }
        if out.contains("(?") { return nil }
        guard out.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        return out
    }

    /// Selectors Safari's CSS parser accepts and that can't break the whole list: plain CSS,
    /// including :has() (Safari 15.4+), but none of the procedural extensions.
    static func isSafeSelector(_ s: String) -> Bool {
        if s.isEmpty || s.count > 2000 { return false }
        if RuleParser.proceduralMarkers.contains(where: { s.contains($0) }) { return false }
        if s.contains("{") || s.contains("}") || s.hasPrefix(",") || s.hasSuffix(",") { return false }
        var depth = 0
        for c in s {
            if c == "(" || c == "[" { depth += 1 }
            if c == ")" || c == "]" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0
    }
}

extension NetworkRule {
    /// "||site.com^" / "||site.com" / "site.com" → "site.com" (for $document exceptions).
    var plainHostLike: String? {
        var b = Substring(pattern)
        if b.hasPrefix("||") { b = b.dropFirst(2) } else if b.hasPrefix("|") { b = b.dropFirst() }
        if b.hasSuffix("^|") { b = b.dropLast(2) } else if b.hasSuffix("^") || b.hasSuffix("|") { b = b.dropLast() }
        if b.hasSuffix("/") { b = b.dropLast() }
        if b == "*" { return includeDomains.first }
        return DomainName.normalize(String(b))
    }
}
