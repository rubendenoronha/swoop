// SPDX-License-Identifier: MIT
//
// Swoop Shield: hostname helpers shared by the DNS layer, the browser-rule converters and
// the UI. Foundation-only so it builds and tests on Linux.
import Foundation

public enum DomainName {
    /// Lowercases, trims whitespace and one trailing dot, strips a leading "*." only when
    /// `stripWildcard` is set. Returns nil for anything that isn't a plausible hostname.
    public static func normalize(_ raw: String, stripWildcard: Bool = false) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix(".") { s.removeLast() }
        if stripWildcard, s.hasPrefix("*.") { s.removeFirst(2) }
        guard isValidHostname(s) else { return nil }
        return s
    }

    /// RFC 1123-ish hostname check (ASCII / punycode only). Allows "_" because real
    /// tracker hostnames use it (e.g. _dmarc-style labels, some CDN names).
    public static func isValidHostname(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard !u.isEmpty, u.count <= 253 else { return false }
        var labelLen = 0
        var labels = 0
        var prev: UInt8 = 0
        for (i, c) in u.enumerated() {
            if c == 0x2E {   // "."
                if labelLen == 0 || prev == 0x2D { return false }
                labels += 1
                labelLen = 0
            } else {
                let ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
                    || (c >= 0x41 && c <= 0x5A)
                if !ok { return false }
                if labelLen == 0 && c == 0x2D { return false }
                labelLen += 1
                if labelLen > 63 { return false }
            }
            prev = c
            if i == u.count - 1 && c == 0x2E { return false }
        }
        if prev == 0x2D { return false }
        labels += 1
        return labels >= 1
    }

    /// Labels from the right: "ads.example.com" → ["com", "example", "ads"].
    public static func reversedLabels(_ s: String) -> [Substring] {
        s.split(separator: ".", omittingEmptySubsequences: false).reversed()
    }

    /// The name itself and each parent: "a.b.example.com" → [a.b.example.com, b.example.com, example.com, com].
    public static func suffixes(_ s: String) -> [Substring] {
        var out: [Substring] = [Substring(s)]
        var idx = s.startIndex
        while let dot = s[idx...].firstIndex(of: ".") {
            let next = s.index(after: dot)
            out.append(s[next...])
            idx = next
        }
        return out
    }

    /// True when `name` is `domain` or a subdomain of it.
    public static func isSubdomain(_ name: String, of domain: String) -> Bool {
        if name == domain { return true }
        guard name.count > domain.count, name.hasSuffix(domain) else { return false }
        let i = name.index(name.endIndex, offsetBy: -domain.count - 1)
        return name[i] == "."
    }

    /// Multi-label public suffixes common enough to matter for "Allow this site". This is
    /// a compact, best-effort subset of the Public Suffix List (not the full list).
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "me.uk", "net.uk", "nhs.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "net.nz", "govt.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "co.kr", "or.kr", "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "com.hk", "com.tw", "com.sg", "com.my", "co.in", "net.in",
        "org.in", "gov.in", "co.za", "org.za", "com.mx", "com.ar", "com.tr", "com.pl", "co.il", "co.id",
        "com.ph", "com.vn", "com.ua", "com.eg", "com.sa", "com.ng", "co.ke", "com.pk", "com.co", "com.pe",
        "github.io", "gitlab.io", "pages.dev", "netlify.app", "vercel.app", "herokuapp.com", "web.app",
        "firebaseapp.com", "blogspot.com", "cloudfront.net", "azurewebsites.net", "s3.amazonaws.com",
        "workers.dev", "fly.dev", "onrender.com", "glitch.me", "repl.co", "myshopify.com",
    ]

    /// Best-effort registrable domain ("eTLD+1"): "news.bbc.co.uk" → "bbc.co.uk".
    public static func registrableDomain(_ host: String) -> String {
        guard let h = normalize(host) else { return host.lowercased() }
        if isIPAddress(h) { return h }
        let labels = h.split(separator: ".")
        guard labels.count > 2 else { return h }
        let last2 = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(last2) {
            return labels.suffix(3).joined(separator: ".")
        }
        let last3 = labels.suffix(3).joined(separator: ".")
        if labels.count > 3 && multiLabelSuffixes.contains(last3) {
            return labels.suffix(4).joined(separator: ".")
        }
        return last2
    }

    /// Host from a URL string or a bare host ("https://www.Example.com:8080/x" → "www.example.com").
    public static func host(fromURLOrHost s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://"), let u = URL(string: t), let h = u.host { return normalize(h) }
        var h = Substring(t)
        if let slash = h.firstIndex(of: "/") { h = h[..<slash] }
        if let colon = h.lastIndex(of: ":"), !h.contains("]") { h = h[..<colon] }
        return normalize(String(h))
    }

    public static func isIPAddress(_ s: String) -> Bool { IPAddress.parse(s) != nil }
}

/// Minimal IPv4/IPv6 text parsing (no inet_pton so it's identical on Linux and macOS).
public enum IPAddress: Hashable, CustomStringConvertible {
    case v4([UInt8])
    case v6([UInt8])

    public static func parse(_ text: String) -> IPAddress? {
        var s = text
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }   // zone id
        if !s.contains(":") {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var b: [UInt8] = []
            for p in parts {
                guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let v = UInt8(p) else { return nil }
                b.append(v)
            }
            return .v4(b)
        }
        // IPv6, possibly with "::" and an embedded IPv4 tail.
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            let items = part.split(separator: ":", omittingEmptySubsequences: false)
            for (i, item) in items.enumerated() {
                if i == items.count - 1, item.contains("."), case .v4(let b)? = IPAddress.parse(String(item)) {
                    out.append(UInt16(b[0]) << 8 | UInt16(b[1]))
                    out.append(UInt16(b[2]) << 8 | UInt16(b[3]))
                } else {
                    guard !item.isEmpty, item.count <= 4, let v = UInt16(item, radix: 16) else { return nil }
                    out.append(v)
                }
            }
            return out
        }
        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 2 {
            guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
            all = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        } else {
            all = head
        }
        guard all.count == 8 else { return nil }
        var b: [UInt8] = []
        for g in all { b.append(UInt8(g >> 8)); b.append(UInt8(g & 0xFF)) }
        return .v6(b)
    }

    public var bytes: [UInt8] {
        switch self { case .v4(let b), .v6(let b): return b }
    }

    public var description: String {
        switch self {
        case .v4(let b): return b.map(String.init).joined(separator: ".")
        case .v6(let b):
            var g: [UInt16] = []
            for i in stride(from: 0, to: 16, by: 2) { g.append(UInt16(b[i]) << 8 | UInt16(b[i + 1])) }
            // Longest run of zeros → "::".
            var bestStart = -1, bestLen = 0, curStart = -1, curLen = 0
            for (i, v) in g.enumerated() {
                if v == 0 {
                    if curStart < 0 { curStart = i; curLen = 0 }
                    curLen += 1
                    if curLen > bestLen { bestLen = curLen; bestStart = curStart }
                } else { curStart = -1 }
            }
            if bestLen < 2 { return g.map { String($0, radix: 16) }.joined(separator: ":") }
            let left = g[..<bestStart].map { String($0, radix: 16) }.joined(separator: ":")
            let right = g[(bestStart + bestLen)...].map { String($0, radix: 16) }.joined(separator: ":")
            return left + "::" + right
        }
    }
}

/// Glob matching for hostname wildcards ("ad*.example.com", "*.tracker.net"). `*` matches
/// any run of characters, including dots.
public enum Glob {
    public static func match(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.utf8), t = Array(text.utf8)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count && (p[pi] == t[ti] || p[pi] == 0x3F /* ? */) {
                pi += 1; ti += 1
            } else if pi < p.count && p[pi] == 0x2A {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == 0x2A { pi += 1 }
        return pi == p.count
    }
}
