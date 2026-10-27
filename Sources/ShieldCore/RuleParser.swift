// SPDX-License-Identifier: MIT
//
// One parser for the filter syntaxes Swoop Shield reads:
//   • Adblock Plus / uBlock Origin / AdGuard network rules (`||ads.example.com^$third-party`,
//     `@@||example.com^$document`, `/regex/`, `$important`, `$badfilter`, `$denyallow`, `$dnstype`…)
//   • cosmetic rules (`##`, `#@#`, `#?#`, `#$#`, `#@$#`) and scriptlets in all three dialects
//     (`##+js(…)` uBO, `#%#//scriptlet(…)` AdGuard, `#$#name arg; name2 arg` ABP snippets)
//   • hosts files (`0.0.0.0 ads.example.com`, `127.0.0.1 …`, `:: …`) and plain domain lists
//   • comments and metadata headers (`! Title:`, `! Expires:`, `# comment`, `[Adblock Plus 2.0]`)
import Foundation

public struct RuleParserOptions: Equatable {
    /// Bare `example.com` lines (domain lists, user rules) block subdomains too.
    public var plainDomainIsSubtree = true
    /// `/regex/` network rules are hostname regexes (DNS lists, AdGuard DNS syntax). For
    /// browser lists (EasyList) they are URL regexes and stay browser-only.
    public var regexIsHostname = false
    /// Keep cosmetic and scriptlet rules (browser layers). DNS-only compiles skip them.
    public var keepCosmetic = true

    public init(plainDomainIsSubtree: Bool = true, regexIsHostname: Bool = false, keepCosmetic: Bool = true) {
        self.plainDomainIsSubtree = plainDomainIsSubtree
        self.regexIsHostname = regexIsHostname
        self.keepCosmetic = keepCosmetic
    }

    public static let dnsList = RuleParserOptions(plainDomainIsSubtree: true, regexIsHostname: true, keepCosmetic: false)
    public static let browserList = RuleParserOptions(plainDomainIsSubtree: true, regexIsHostname: false, keepCosmetic: true)
    public static let userRules = RuleParserOptions(plainDomainIsSubtree: true, regexIsHostname: true, keepCosmetic: true)
}

public enum RuleParser {
    /// Modifiers that make a network rule browser-only (the DNS layer can't see them).
    static let browserOnlyModifiers: Set<String> = [
        "third-party", "3p", "~third-party", "~3p", "first-party", "1p", "~first-party", "strict1p", "strict3p",
        "domain", "from", "to", "script", "image", "stylesheet", "css", "subdocument", "frame", "xmlhttprequest", "xhr",
        "object", "media", "font", "websocket", "ping", "other", "match-case", "redirect", "redirect-rule", "csp",
        "removeparam", "queryprune", "header", "permissions", "replace", "cookie", "stealth", "jsonprune",
        "method", "elemhide", "ehide", "generichide", "ghide", "specifichide", "shide", "genericblock", "content",
        "jsinject", "urlblock", "extension", "inline-script", "inline-font", "empty", "mp4", "app", "network",
        "hls", "referrerpolicy", "urltransform", "uritransform", "rewrite", "object-subrequest", "webrtc",
    ]
    /// Modifiers the DNS layer understands.
    static let dnsModifiers: Set<String> = ["important", "badfilter", "denyallow", "dnstype", "all", "document", "doc", "popup"]
    /// AdGuard-Home-only modifiers Swoop doesn't implement (rules carrying them are skipped).
    static let unsupportedDNSModifiers: Set<String> = ["client", "ctag", "dnsrewrite"]

    public static let resourceTypeAliases: [String: ResourceType] = [
        "document": .document, "doc": .document, "subdocument": .subdocument, "frame": .subdocument,
        "stylesheet": .stylesheet, "css": .stylesheet, "script": .script, "image": .image, "font": .font,
        "media": .media, "xmlhttprequest": .xmlhttprequest, "xhr": .xmlhttprequest, "websocket": .websocket,
        "ping": .ping, "object": .object, "object-subrequest": .object, "other": .other, "popup": .popup,
    ]

    /// Parses a whole list. Returns every line's result (comments included) in order.
    public static func parse(text: String, options: RuleParserOptions = .browserList) -> [ParsedLine] {
        var out: [ParsedLine] = []
        out.reserveCapacity(text.utf8.count / 30)
        text.enumerateLines { line, _ in out.append(parseLine(line, options: options)) }
        return out
    }

    public static func parseLine(_ rawLine: String, options: RuleParserOptions = .browserList) -> ParsedLine {
        var r = ParsedLine()
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { r.isComment = true; return r }
        let first = line.first!

        // Comments and metadata.
        if first == "!" || (first == "[" && line.hasSuffix("]") && !line.contains("##")) {
            r.isComment = true
            if first == "!" { r.metadata = metadata(in: line.dropFirst()) }
            return r
        }
        if first == "#" && !line.hasPrefix("##") && !line.hasPrefix("#@#") && !line.hasPrefix("#?#")
            && !line.hasPrefix("#$#") && !line.hasPrefix("#%#") && !line.hasPrefix("#@$#") && !line.hasPrefix("#@?#") && !line.hasPrefix("#@%#") {
            r.isComment = true   // hosts-file comment
            r.metadata = metadata(in: line.dropFirst())
            return r
        }

        // Cosmetic / scriptlet rules: find the separator.
        if let cos = cosmeticSeparator(in: line) {
            if !options.keepCosmetic { r.isComment = true; return r }
            return parseCosmetic(line, sep: cos)
        }

        // hosts-file syntax: "<ip> host [host…]  # comment".
        if let hosts = parseHosts(line) {
            if hosts.isEmpty { r.isComment = true; return r }   // "127.0.0.1 localhost" and friends
            r.dns = hosts[0]
            if hosts.count > 1 { r.metadata = ("hosts-extra", hosts.dropFirst().map { $0.pattern.value }.joined(separator: " ")) }
            return r
        }

        return parseNetwork(line, options: options)
    }

    /// Hosts lines can carry several names. Callers that need all of them use this.
    public static func hostsEntries(_ line: String) -> [DNSRule]? { parseHosts(line.trimmingCharacters(in: .whitespaces)) }

    // MARK: metadata

    static func metadata(in s: Substring) -> (key: String, value: String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let key = t[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let known: Set<String> = ["title", "expires", "version", "homepage", "license", "licence", "checksum", "last modified",
                                  "description", "timeupdated", "updated"]
        guard known.contains(key), !value.isEmpty else { return nil }
        return (key == "licence" ? "license" : key, value)
    }

    /// "4 days (update frequency)", "12 hours", "1 hours" → seconds.
    public static func expiresSeconds(_ value: String) -> TimeInterval? {
        let parts = value.lowercased().split(whereSeparator: { $0 == " " || $0 == "(" })
        guard parts.count >= 2, let n = Double(parts[0]), n > 0 else { return nil }
        if parts[1].hasPrefix("day") { return n * 86_400 }
        if parts[1].hasPrefix("hour") { return n * 3_600 }
        if parts[1].hasPrefix("min") { return n * 60 }
        return nil
    }

    // MARK: hosts

    static func parseHosts(_ line: String) -> [DNSRule]? {
        let noComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        let fields = noComment.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2, let ip = IPAddress.parse(String(fields[0])) else { return nil }
        _ = ip
        let ignored: Set<String> = ["localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost",
                                    "ip6-loopback", "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters",
                                    "ip6-allhosts", "0.0.0.0"]
        var out: [DNSRule] = []
        for f in fields.dropFirst() {
            let name = String(f)
            if ignored.contains(name.lowercased()) { continue }
            guard let n = DomainName.normalize(name), !DomainName.isIPAddress(n) else { continue }
            out.append(DNSRule(pattern: HostPattern(.exact, n)))
        }
        return out
    }

    // MARK: network

    static func parseNetwork(_ line: String, options: RuleParserOptions) -> ParsedLine {
        var r = ParsedLine()
        var body = Substring(line)
        var isException = false
        if body.hasPrefix("@@") { isException = true; body = body.dropFirst(2) }

        // Split off $options (a "$" that isn't inside a /regex/).
        var optionText: Substring?
        if body.hasPrefix("/"), let close = regexEnd(body) {
            let after = body[body.index(after: close)...]
            if after.hasPrefix("$") { optionText = after.dropFirst() }
            else if !after.isEmpty { r.error = "Unexpected text after /regex/"; return r }
            body = body[...close]
        } else if let d = body.lastIndex(of: "$"), !body[d...].contains("/") || body[body.index(after: d)...].contains("=") {
            optionText = body[body.index(after: d)...]
            body = body[..<d]
        }

        var nr = NetworkRule(pattern: "", isException: isException)
        var dnsOK = true
        var important = false, badfilter = false
        var denyAllow: [String] = [], dnsTypes: [String] = [], exDNSTypes: [String] = []

        if let opts = optionText {
            for rawOpt in splitOptions(opts) {
                var opt = rawOpt.trimmingCharacters(in: .whitespaces)
                if opt.isEmpty { continue }
                var negated = false
                if opt.hasPrefix("~") { negated = true; opt.removeFirst() }
                let parts = opt.split(separator: "=", maxSplits: 1)
                let name = parts[0].lowercased()
                let value = parts.count > 1 ? String(parts[1]) : ""
                let key = (negated ? "~" : "") + name
                if unsupportedDNSModifiers.contains(name) { dnsOK = false }
                if browserOnlyModifiers.contains(name) || browserOnlyModifiers.contains(key) { dnsOK = false }
                switch name {
                case "important": important = true; nr.important = true
                case "badfilter": badfilter = true
                case "denyallow":
                    denyAllow = value.split(separator: "|").compactMap { DomainName.normalize(String($0)) }
                case "dnstype":
                    for t in value.split(separator: "|") {
                        if t.hasPrefix("~") { exDNSTypes.append(t.dropFirst().lowercased()) } else { dnsTypes.append(t.lowercased()) }
                    }
                case "third-party", "3p": nr.thirdParty = !negated
                case "first-party", "1p", "strict1p": nr.thirdParty = negated
                case "strict3p": nr.thirdParty = true
                case "match-case": nr.matchCase = !negated
                case "domain", "from":
                    for d in value.split(separator: "|") {
                        if d.hasPrefix("~") { if let n = DomainName.normalize(String(d.dropFirst()), stripWildcard: true) { nr.excludeDomains.append(n) } }
                        else if let n = DomainName.normalize(String(d), stripWildcard: true) { nr.includeDomains.append(n) }
                    }
                case "document", "doc":
                    if isException { nr.documentException = true } else { nr.resourceTypes.insert(.document) }
                case "all":
                    break   // every type incl. document; for DNS a plain block
                case "elemhide", "ehide": if isException { nr.elemHideException = true }
                case "generichide", "ghide": if isException { nr.genericHideException = true }
                case "redirect", "redirect-rule": nr.redirect = value
                case "popup": if negated { nr.excludedResourceTypes.insert(.popup) } else { nr.resourceTypes.insert(.popup) }
                case "client", "ctag", "dnsrewrite", "to", "app", "network", "csp", "removeparam", "queryprune", "header",
                     "permissions", "replace", "cookie", "stealth", "jsonprune", "method", "empty", "mp4", "specifichide",
                     "shide", "genericblock", "content", "jsinject", "urlblock", "extension", "inline-script", "inline-font",
                     "hls", "referrerpolicy", "urltransform", "uritransform", "rewrite", "webrtc", "strict-first-party",
                     "strict-third-party":
                    // Understood but not convertible to DNS / Safari / DNR: keep the rule only if
                    // it is otherwise meaningful (handled by the converters' skip counters).
                    if ["csp", "removeparam", "queryprune", "header", "permissions", "replace", "cookie", "jsonprune",
                        "urltransform", "uritransform", "rewrite", "hls", "referrerpolicy", "to", "method", "app", "network",
                        "client", "ctag", "dnsrewrite"].contains(name) {
                        r.error = "Unsupported modifier $\(name)"
                    }
                default:
                    if let t = resourceTypeAliases[name] {
                        if negated { nr.excludedResourceTypes.insert(t) } else { nr.resourceTypes.insert(t) }
                    } else if !dnsModifiers.contains(name) {
                        r.error = "Unknown modifier $\(name)"
                        return r
                    }
                }
            }
        }

        var pattern = String(body)
        if pattern.isEmpty || pattern == "*" {
            // "$domain=example.com" / "@@$document,domain=x": pattern-less rules.
            if nr.includeDomains.isEmpty && nr.resourceTypes.isEmpty && nr.thirdParty == nil && !nr.documentException
                && !nr.genericHideException && !nr.elemHideException {
                if r.error == nil { r.error = "Rule matches everything" }
                return r
            }
            pattern = "*"
            dnsOK = false
        }

        // Regex rules.
        if pattern.count > 2 && pattern.hasPrefix("/") && pattern.hasSuffix("/") {
            let src = String(pattern.dropFirst().dropLast())
            guard (try? NSRegularExpression(pattern: src, options: [.caseInsensitive])) != nil else {
                r.error = "Invalid regular expression"
                return r
            }
            nr.pattern = src
            nr.isRegex = true
            if options.regexIsHostname && dnsOK {
                let dr = DNSRule(pattern: HostPattern(.regex, src), isException: isException, important: important,
                                 denyAllow: denyAllow, dnsTypes: dnsTypes, excludedDNSTypes: exDNSTypes)
                if badfilter { r.badfilterDNS = dr } else { r.dns = dr }
            }
            if !options.regexIsHostname {
                if badfilter { r.badfilterNetwork = nr } else if r.error == nil { r.network = nr }
            }
            return r
        }

        nr.pattern = pattern
        // DNS form: "||host^", "|host^", "host" (bare domain), "||ad*.host^".
        if dnsOK, let hp = hostPattern(from: pattern, options: options) {
            let dr = DNSRule(pattern: hp, isException: isException, important: important,
                             denyAllow: denyAllow, dnsTypes: dnsTypes, excludedDNSTypes: exDNSTypes)
            if badfilter { r.badfilterDNS = dr } else { r.dns = dr }
        }
        // Bare domains in domain lists are DNS-only; everything else also feeds the browser layer.
        let bareDomain = !pattern.contains("|") && !pattern.contains("^") && !pattern.contains("/")
            && !pattern.contains("*") && DomainName.isValidHostname(pattern) && pattern.contains(".")
        if bareDomain {
            // Treat as ||domain^ for browsers too (that is what a user typing "ads.com" means).
            if let n = DomainName.normalize(pattern) { nr.pattern = "||\(n)^" }
        }
        if badfilter { r.badfilterNetwork = nr } else if r.error == nil { r.network = nr }
        if r.network == nil && r.dns == nil && r.badfilterDNS == nil && r.badfilterNetwork == nil && r.error == nil {
            r.error = "Nothing to apply"
        }
        return r
    }

    /// Host-only patterns the DNS layer can apply.
    static func hostPattern(from p: String, options: RuleParserOptions) -> HostPattern? {
        var s = Substring(p)
        var kind: HostPatternKind
        if s.hasPrefix("||") {
            s = s.dropFirst(2); kind = .subtree
        } else if s.hasPrefix("|") {
            s = s.dropFirst()
            if s.hasPrefix("http://") || s.hasPrefix("https://") {
                s = s.drop(while: { $0 != "/" }).dropFirst(2)
            }
            kind = .exact
        } else if s.hasPrefix("*.") {
            kind = .wildcard
        } else {
            // Bare hostname (domain lists, user rules).
            let host = s.hasSuffix("^") ? s.dropLast() : s
            guard !host.contains("/"), !host.contains("^"), !host.contains("|"), host.contains(".") || host.contains("*") else { return nil }
            if host.contains("*") {
                let g = host.lowercased()
                return isPlausibleHostGlob(g) ? HostPattern(.wildcard, g) : nil
            }
            guard let n = DomainName.normalize(String(host)) else { return nil }
            return HostPattern(options.plainDomainIsSubtree ? .subtree : .exact, n)
        }
        // Must end at the host: "^", "^|", "|" or nothing.
        if s.hasSuffix("^|") { s = s.dropLast(2) } else if s.hasSuffix("^") { s = s.dropLast() } else if s.hasSuffix("|") { s = s.dropLast() }
        if s.hasSuffix(".") { s = s.dropLast() }
        guard !s.isEmpty, !s.contains("/"), !s.contains("^"), !s.contains("|"), !s.contains(":"), !s.contains("=") else { return nil }
        if s.contains("*") {
            // "||ad*.example.com^": a glob over the whole hostname.
            let g = s.lowercased()
            guard isPlausibleHostGlob(g) else { return nil }
            return HostPattern(.wildcard, g)
        }
        guard let n = DomainName.normalize(String(s)) else { return nil }
        // A single-label "||com^" or a bare IP would be absurd at DNS level.
        guard n.contains("."), !DomainName.isIPAddress(n) else { return nil }
        return HostPattern(kind == .wildcard ? .subtree : kind, n)
    }

    static func isPlausibleHostGlob(_ g: String) -> Bool {
        guard g.contains("."), g.replacingOccurrences(of: "*", with: "").count >= 3 else { return false }
        return g.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "." || $0 == "*" || $0 == "_" }
    }

    /// Index of the closing "/" of a /regex/ at the start of `s` (ignores escaped slashes).
    static func regexEnd(_ s: Substring) -> Substring.Index? {
        guard s.count >= 3 else { return nil }
        var i = s.index(after: s.startIndex)
        var escaped = false
        var inClass = false
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "[" { inClass = true }
            else if c == "]" { inClass = false }
            else if c == "/" && !inClass {
                let next = s.index(after: i)
                if next == s.endIndex || s[next] == "$" { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Splits "$a,domain=x|y,b" on commas that aren't escaped or inside a regex value.
    static func splitOptions(_ s: Substring) -> [String] {
        var out: [String] = []
        var cur = ""
        var escaped = false
        var depth = 0
        for c in s {
            if escaped { cur.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; cur.append(c); continue }
            if c == "/" { depth = depth == 0 ? 1 : 0 }
            if c == "," && depth == 0 { out.append(cur); cur = ""; continue }
            cur.append(c)
        }
        out.append(cur)
        return out
    }

    // MARK: cosmetic

    enum CosSep: String {
        case hide = "##", hideException = "#@#", procedural = "#?#", proceduralException = "#@?#",
             style = "#$#", styleException = "#@$#", adguardJS = "#%#", adguardJSException = "#@%#"
    }

    static func cosmeticSeparator(in line: String) -> (range: Range<String.Index>, sep: CosSep)? {
        // Find the first '#' that starts a known separator. Domains can't contain '#'.
        var idx = line.startIndex
        while let h = line[idx...].firstIndex(of: "#") {
            let rest = line[h...]
            for sep in [CosSep.proceduralException, .styleException, .adguardJSException, .hideException, .procedural, .style, .adguardJS, .hide] {
                if rest.hasPrefix(sep.rawValue) {
                    // Only a cosmetic rule if what precedes is a domain list (no "/", "^", "|" except "|" never) or empty.
                    let before = line[..<h]
                    if before.contains("/") || before.contains("^") || before.contains("$") || before.contains(" ") { return nil }
                    return (h..<line.index(h, offsetBy: sep.rawValue.count), sep)
                }
            }
            idx = line.index(after: h)
            if idx >= line.endIndex { break }
        }
        return nil
    }

    static let proceduralMarkers = [":has-text(", ":-abp-has(", ":-abp-contains(", ":contains(", ":upward(", ":xpath(",
                                    ":matches-css(", ":matches-css-before(", ":matches-css-after(", ":min-text-length(",
                                    ":watch-attr(", ":remove(", ":style(", ":matches-path(", ":others(", ":if(", ":if-not(",
                                    ":nth-ancestor(", ":-abp-properties(", ":matches-attr(", ":matches-prop(", ":remove-attr(",
                                    ":remove-class(", ":matches-media("]

    static func parseCosmetic(_ line: String, sep: (range: Range<String.Index>, sep: CosSep)) -> ParsedLine {
        var r = ParsedLine()
        let domainPart = String(line[..<sep.range.lowerBound])
        let body = String(line[sep.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        var inc: [String] = [], exc: [String] = []
        if !domainPart.isEmpty {
            for d in domainPart.split(separator: ",") {
                let t = d.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("~") {
                    if let n = cosmeticDomain(String(t.dropFirst())) { exc.append(n) }
                } else if let n = cosmeticDomain(t) { inc.append(n) }
            }
            if inc.isEmpty && exc.isEmpty { r.error = "Bad domain list"; return r }
        }
        guard !body.isEmpty else { r.error = "Empty selector"; return r }

        switch sep.sep {
        case .hide, .hideException:
            let isEx = sep.sep == .hideException
            if body.hasPrefix("+js(") {
                guard body.hasSuffix(")") else { r.error = "Bad +js()"; return r }
                let inner = String(body.dropFirst(4).dropLast())
                let args = splitScriptletArgs(inner, quoted: false)
                guard let name = args.first, !name.isEmpty || isEx else { r.error = "Empty scriptlet"; return r }
                r.scriptlets = [ScriptletRule(includeDomains: inc, excludeDomains: exc, name: Scriptlets.canonicalName(name),
                                              args: Array(args.dropFirst()), isException: isEx)]
                return r
            }
            if body.hasPrefix("^") { r.error = "HTML filtering isn't supported"; return r }
            let procedural = proceduralMarkers.contains { body.contains($0) }
            r.cosmetic = CosmeticRule(includeDomains: inc, excludeDomains: exc, selector: body, isException: isEx,
                                      kind: procedural ? .procedural : .hide)
        case .procedural, .proceduralException:
            r.cosmetic = CosmeticRule(includeDomains: inc, excludeDomains: exc, selector: body,
                                      isException: sep.sep == .proceduralException, kind: .procedural)
        case .style, .styleException:
            let isEx = sep.sep == .styleException
            if body.contains("{") && body.hasSuffix("}") {
                r.cosmetic = CosmeticRule(includeDomains: inc, excludeDomains: exc, selector: body, isException: isEx, kind: .style)
            } else {
                // ABP snippets: "name arg arg; name2 arg".
                var list: [ScriptletRule] = []
                for cmd in body.split(separator: ";") {
                    let args = splitScriptletArgs(String(cmd), quoted: true, spaceSeparated: true)
                    guard let name = args.first, !name.isEmpty else { continue }
                    list.append(ScriptletRule(includeDomains: inc, excludeDomains: exc, name: Scriptlets.canonicalName(name),
                                              args: Array(args.dropFirst()), isException: isEx))
                }
                if list.isEmpty { r.error = "Empty snippet"; return r }
                r.scriptlets = list
            }
        case .adguardJS, .adguardJSException:
            let isEx = sep.sep == .adguardJSException
            guard body.hasPrefix("//scriptlet(") && body.hasSuffix(")") else {
                r.error = "Raw JavaScript rules aren't supported (only //scriptlet)"
                return r
            }
            let inner = String(body.dropFirst("//scriptlet(".count).dropLast())
            let args = splitScriptletArgs(inner, quoted: true)
            guard let name = args.first, !name.isEmpty else { r.error = "Empty scriptlet"; return r }
            r.scriptlets = [ScriptletRule(includeDomains: inc, excludeDomains: exc, name: Scriptlets.canonicalName(name),
                                          args: Array(args.dropFirst()), isException: isEx)]
        }
        return r
    }

    /// Cosmetic domain entries can be "example.com", "*.example.com", "example.*" (entity).
    static func cosmeticDomain(_ s: String) -> String? {
        let t = s.lowercased()
        if t.hasSuffix(".*") {
            let base = String(t.dropLast(2))
            return DomainName.isValidHostname(base) ? t : nil
        }
        return DomainName.normalize(t, stripWildcard: true)
    }

    /// Splits scriptlet arguments: uBO style `a, b\, c` or quoted `'a', "b"`, or ABP snippets `a 'b c'`.
    static func splitScriptletArgs(_ s: String, quoted: Bool, spaceSeparated: Bool = false) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var escaped = false
        var hadQuote = false
        let sepChar: Character = spaceSeparated ? " " : ","
        for c in s {
            if escaped {
                // "\," and "\'" are escapes; any other backslash belongs to the value (regexes).
                if c != sepChar && c != "'" && c != "\"" && c != "\\" { cur.append("\\") }
                cur.append(c); escaped = false; continue
            }
            if c == "\\" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
                continue
            }
            if (c == "'" || c == "\"") && (quoted || cur.trimmingCharacters(in: .whitespaces).isEmpty) && (quoted || spaceSeparated) {
                if cur.trimmingCharacters(in: .whitespaces).isEmpty { cur = "" }
                quote = c; hadQuote = true; continue
            }
            if c == sepChar {
                let t = hadQuote ? cur : cur.trimmingCharacters(in: .whitespaces)
                if !(spaceSeparated && t.isEmpty && !hadQuote) { out.append(t) }
                cur = ""; hadQuote = false
                continue
            }
            cur.append(c)
        }
        let t = hadQuote ? cur : cur.trimmingCharacters(in: .whitespaces)
        if !(t.isEmpty && !hadQuote && (spaceSeparated || out.isEmpty)) { out.append(t) }
        return out
    }
}

/// Scriptlet names across uBO, AdGuard and ABP, folded to the names Swoop's browser
/// extension implements (Extensions/webext/scriptlets.js).
public enum Scriptlets {
    public static let implemented: Set<String> = [
        "set-constant", "abort-on-property-read", "abort-on-property-write", "abort-current-inline-script",
        "json-prune", "json-prune-fetch-response", "json-prune-xhr-response", "prevent-setTimeout",
        "prevent-setInterval", "prevent-addEventListener", "prevent-fetch", "prevent-xhr", "remove-attr",
        "remove-class", "no-window-open-if", "prevent-eval-if", "set-cookie", "set-local-storage-item",
    ]

    static let aliases: [String: String] = [
        "set": "set-constant", "set-constant.js": "set-constant", "override-property-read": "set-constant",
        "aopr": "abort-on-property-read", "abort-on-property-read.js": "abort-on-property-read",
        "aopw": "abort-on-property-write", "abort-on-property-write.js": "abort-on-property-write",
        "acis": "abort-current-inline-script", "abort-current-inline-script.js": "abort-current-inline-script",
        "abort-current-script": "abort-current-inline-script", "acs": "abort-current-inline-script",
        "json-prune.js": "json-prune", "json-prune-fetch-response.js": "json-prune-fetch-response",
        "json-prune-xhr-response.js": "json-prune-xhr-response",
        "nostif": "prevent-setTimeout", "no-setTimeout-if": "prevent-setTimeout", "setTimeout-defuser": "prevent-setTimeout",
        "no-settimeout-if": "prevent-setTimeout", "prevent-settimeout": "prevent-setTimeout",
        "nosiif": "prevent-setInterval", "no-setInterval-if": "prevent-setInterval", "setInterval-defuser": "prevent-setInterval",
        "no-setinterval-if": "prevent-setInterval", "prevent-setinterval": "prevent-setInterval",
        "aeld": "prevent-addEventListener", "addEventListener-defuser": "prevent-addEventListener",
        "prevent-addeventlistener": "prevent-addEventListener",
        "no-fetch-if": "prevent-fetch", "no-xhr-if": "prevent-xhr", "ra": "remove-attr", "remove-attr.js": "remove-attr",
        "rc": "remove-class", "remove-class.js": "remove-class", "nowoif": "no-window-open-if",
        "prevent-window-open": "no-window-open-if", "window.open-defuser": "no-window-open-if",
        "noeval-if": "prevent-eval-if", "prevent-eval-if": "prevent-eval-if",
        "set-cookie.js": "set-cookie", "set-local-storage-item.js": "set-local-storage-item",
    ]

    public static func canonicalName(_ raw: String) -> String {
        var n = raw.trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("ubo-") { n.removeFirst(4) }
        if n.hasPrefix("abp-") { n.removeFirst(4) }
        if let a = aliases[n] ?? aliases[n.lowercased()] { return a }
        if n.hasSuffix(".js") { n.removeLast(3) }
        return aliases[n] ?? n
    }

    public static func isImplemented(_ name: String) -> Bool { implemented.contains(name) }
}
