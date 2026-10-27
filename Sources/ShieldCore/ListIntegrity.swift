// SPDX-License-Identifier: MIT
//
// Checks a downloaded filter list before Shield uses it. Upstream lists aren't signed, so
// Shield defends against the realistic failures: captive-portal pages, truncated or empty
// downloads, the wrong file, a list that suddenly lost most of its rules, and (when a
// Swoop-signed manifest is configured) any byte-level difference from the snapshot the
// manifest pins. A list that fails keeps the last good copy in use.
import Foundation

public struct ListRecord: Codable, Equatable {
    public var id: String
    public var sha256: String
    public var ruleCount: Int
    public var dnsRuleCount: Int
    public var fetchedAt: Date
    public var title: String?
    public var version: String?
    public var expiresSeconds: Double?
    public var sourceURL: String

    public init(id: String, sha256: String, ruleCount: Int, dnsRuleCount: Int, fetchedAt: Date, title: String?,
                version: String?, expiresSeconds: Double?, sourceURL: String) {
        self.id = id; self.sha256 = sha256; self.ruleCount = ruleCount; self.dnsRuleCount = dnsRuleCount
        self.fetchedAt = fetchedAt; self.title = title; self.version = version; self.expiresSeconds = expiresSeconds
        self.sourceURL = sourceURL
    }
}

public enum ListRejection: Error, Equatable, CustomStringConvertible {
    case tooSmall(Int), tooLarge(Int), notText, looksLikeHTML, wrongTitle(String?), tooFewRules(Int, Int),
         suddenDrop(Int, Int), hashMismatch(expected: String, got: String), badSignature, disallowedHost(String)

    public var description: String {
        switch self {
        case .tooSmall(let n): return "Download is only \(n) bytes"
        case .tooLarge(let n): return "Download is too large (\(n / 1_000_000) MB)"
        case .notText: return "Download isn't a text filter list"
        case .looksLikeHTML: return "Got a web page instead of a list (captive portal or error page?)"
        case .wrongTitle(let t): return "Unexpected list title \(t.map { "\"\($0)\"" } ?? "(none)")"
        case .tooFewRules(let n, let min): return "Only \(n) rules (expected at least \(min))"
        case .suddenDrop(let n, let prev): return "Rules dropped from \(prev) to \(n); keeping the previous copy"
        case .hashMismatch(let e, let g): return "SHA-256 \(g.prefix(12))… doesn't match the signed manifest (\(e.prefix(12))…)"
        case .badSignature: return "The list manifest's signature is invalid"
        case .disallowedHost(let h): return "Refusing to download from \(h)"
        }
    }
}

/// Optional Swoop-signed manifest pinning list snapshots by hash.
public struct ListManifest: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var sha256: String
        public var rules: Int
        public var url: String?
    }
    public var version: Int
    public var generated: Date
    public var lists: [String: Entry]

    /// Parses `data` only if `verify(data, signature)` accepts the detached signature.
    public static func load(data: Data, signature: Data, verify: (Data, Data) -> Bool) throws -> ListManifest {
        guard verify(data, signature) else { throw ListRejection.badSignature }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ListManifest.self, from: data)
    }
}

public enum ListIntegrity {
    public static let maxBytes = 60_000_000
    /// Refuse an update that loses more than this share of the previous copy's rules.
    public static let maxDrop = 0.5

    public static func verify(data: Data, source: FilterListSource, fetchedFrom url: String, previous: ListRecord?,
                              expectedSHA256: String? = nil, now: Date = Date()) -> Result<(ListRecord, String), ListRejection> {
        if let host = URL(string: url)?.host?.lowercased(), !FilterListCatalog.allowedHosts.contains(host) {
            return .failure(.disallowedHost(host))
        }
        guard data.count >= 64 else { return .failure(.tooSmall(data.count)) }
        guard data.count <= maxBytes else { return .failure(.tooLarge(data.count)) }
        let digest = SHA256.hash(data).hex
        if let e = expectedSHA256, e.lowercased() != digest { return .failure(.hashMismatch(expected: e.lowercased(), got: digest)) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return .failure(.notText) }
        let head = text.prefix(512).lowercased()
        if head.contains("<!doctype html") || head.contains("<html") || head.contains("<head>") { return .failure(.looksLikeHTML) }
        if text.utf8.prefix(4096).contains(0) { return .failure(.notText) }

        var title: String?, version: String?, expires: Double?
        var rules = 0, dnsRules = 0
        text.enumerateLines { line, _ in
            let p = RuleParser.parseLine(line, options: source.parserOptions)
            if let m = p.metadata {
                switch m.key {
                case "title": if title == nil { title = m.value }
                case "version": if version == nil { version = m.value }
                case "expires": if expires == nil { expires = RuleParser.expiresSeconds(m.value) }
                default: break
                }
            }
            if p.dns != nil { dnsRules += 1 }
            if p.dns != nil || p.network != nil || p.cosmetic != nil || !p.scriptlets.isEmpty { rules += 1 }
        }
        if let want = source.expectedTitle {
            guard let t = title, t.lowercased().contains(want.lowercased()) else { return .failure(.wrongTitle(title)) }
        }
        guard rules >= source.minRules else { return .failure(.tooFewRules(rules, source.minRules)) }
        if let prev = previous, prev.ruleCount > 0, Double(rules) < Double(prev.ruleCount) * (1 - maxDrop) {
            return .failure(.suddenDrop(rules, prev.ruleCount))
        }
        let rec = ListRecord(id: source.id, sha256: digest, ruleCount: rules, dnsRuleCount: dnsRules, fetchedAt: now,
                             title: title, version: version, expiresSeconds: expires, sourceURL: url)
        return .success((rec, text))
    }

    /// When the list is next due: its own `! Expires:` if shorter than a day (clamped to at
    /// least 6 h to be polite to maintainers), otherwise daily.
    public static func nextUpdate(after rec: ListRecord) -> Date {
        let daily: Double = 86_400
        let e = rec.expiresSeconds.map { min(daily, max(6 * 3_600, $0)) } ?? daily
        return rec.fetchedAt.addingTimeInterval(e)
    }
}
