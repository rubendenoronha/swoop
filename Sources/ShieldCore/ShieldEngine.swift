// SPDX-License-Identifier: MIT
//
// The decision core shared by the system extension, the local resolver and the tests:
// config (pauses, allowlist, custom rules) + compiled lists → block / allow / pass for a
// lookup, CNAME uncloaking of upstream answers, encrypted-DNS flow verdicts, and local
// stats + query log. Nothing here sends data anywhere.
import Foundation

public struct AppPause: Codable, Equatable, Hashable, Identifiable {
    /// Code-signing identifier / bundle ID ("com.google.Chrome").
    public var id: String
    public var name: String
    /// nil = until switched back on.
    public var until: Date?

    public init(id: String, name: String, until: Date? = nil) {
        self.id = id
        self.name = name
        self.until = until
    }
}

public struct SitePause: Codable, Equatable, Hashable, Identifiable {
    public var domain: String
    public var until: Date?
    public var id: String { domain }

    public init(domain: String, until: Date? = nil) {
        self.domain = domain
        self.until = until
    }
}

public enum Upstream: Codable, Equatable {
    /// Whatever DNS servers macOS was given (DHCP, VPN). Default.
    case system
    /// Plain DNS to these servers.
    case servers([String])
    /// DNS over HTTPS. `bootstrapIPs` avoid resolving the DoH host through Shield itself.
    case doh(url: String, bootstrapIPs: [String])

    public var hosts: Set<String> {
        if case .doh(let url, _) = self, let h = URL(string: url)?.host?.lowercased() { return [h] }
        return []
    }

    public var ips: Set<String> {
        switch self {
        case .system: return []
        case .servers(let s): return Set(s)
        case .doh(_, let b): return Set(b)
        }
    }

    /// Ready-made encrypted upstreams (their own filtering, if any, is in addition to Shield's).
    public static let presets: [(title: String, upstream: Upstream)] = [
        ("Quad9 (malware blocking, Switzerland)", .doh(url: "https://dns.quad9.net/dns-query", bootstrapIPs: ["9.9.9.9", "149.112.112.112"])),
        ("Cloudflare", .doh(url: "https://cloudflare-dns.com/dns-query", bootstrapIPs: ["1.1.1.1", "1.0.0.1"])),
        ("Mullvad (no logging)", .doh(url: "https://dns.mullvad.net/dns-query", bootstrapIPs: ["194.242.2.2"])),
    ]
}

/// Everything the user can set for Shield. Shared by the app, the system extension and the
/// local resolver (JSON).
public struct ShieldConfig: Codable, Equatable {
    public var enabled = true
    public var enabledLists: [String] = FilterListCatalog.defaultEnabledIDs
    public var blockResponse: BlockResponse = .nxdomain
    public var encryptedDNS: EncryptedDNSMode = .blockBypass
    public var blockPrivateRelay = false
    public var cnameUncloaking = true
    public var builtInCloakTrackers = true
    public var logQueries = true
    public var logRetentionHours = 24
    public var customRules = ""
    public var allowlist: [String] = []
    public var pausedUntil: Date?
    public var appPauses: [AppPause] = []
    public var sitePauses: [SitePause] = []
    public var upstream: Upstream = .system
    /// Pax is installed: no DNS-level layers, no DNS-bypass blocking, Pax's servers never blocked
    /// (set by Swoop.app from PaxCompatibility; see docs/SHIELD.md, "Using Swoop with Pax").
    public var paxCompatible = false
    /// Next to Pax, also run the drop-only content filter (off unless the user turns it on).
    public var paxContentFilter = false

    public init() {}

    public func isPaused(at now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }

    /// Drops pauses that have run out.
    public func pruned(at now: Date) -> ShieldConfig {
        var c = self
        if let p = c.pausedUntil, p <= now { c.pausedUntil = nil }
        c.appPauses.removeAll { ($0.until.map { $0 <= now }) ?? false }
        c.sitePauses.removeAll { ($0.until.map { $0 <= now }) ?? false }
        return c
    }

    public var userRules: UserRules { UserRules(allowlist: allowlist, customRules: customRules) }

    // Tolerant decoding: a config written by an older/newer Swoop still loads.
    enum CodingKeys: String, CodingKey {
        case enabled, enabledLists, blockResponse, encryptedDNS, blockPrivateRelay, cnameUncloaking, builtInCloakTrackers,
             logQueries, logRetentionHours, customRules, allowlist, pausedUntil, appPauses, sitePauses, upstream,
             paxCompatible, paxContentFilter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShieldConfig()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        enabledLists = (try? c.decode([String].self, forKey: .enabledLists)) ?? d.enabledLists
        blockResponse = (try? c.decode(BlockResponse.self, forKey: .blockResponse)) ?? d.blockResponse
        encryptedDNS = (try? c.decode(EncryptedDNSMode.self, forKey: .encryptedDNS)) ?? d.encryptedDNS
        blockPrivateRelay = (try? c.decode(Bool.self, forKey: .blockPrivateRelay)) ?? d.blockPrivateRelay
        cnameUncloaking = (try? c.decode(Bool.self, forKey: .cnameUncloaking)) ?? d.cnameUncloaking
        builtInCloakTrackers = (try? c.decode(Bool.self, forKey: .builtInCloakTrackers)) ?? d.builtInCloakTrackers
        logQueries = (try? c.decode(Bool.self, forKey: .logQueries)) ?? d.logQueries
        logRetentionHours = (try? c.decode(Int.self, forKey: .logRetentionHours)) ?? d.logRetentionHours
        customRules = (try? c.decode(String.self, forKey: .customRules)) ?? d.customRules
        allowlist = (try? c.decode([String].self, forKey: .allowlist)) ?? d.allowlist
        pausedUntil = try? c.decode(Date.self, forKey: .pausedUntil)
        appPauses = (try? c.decode([AppPause].self, forKey: .appPauses)) ?? []
        sitePauses = (try? c.decode([SitePause].self, forKey: .sitePauses)) ?? []
        upstream = (try? c.decode(Upstream.self, forKey: .upstream)) ?? .system
        paxCompatible = (try? c.decode(Bool.self, forKey: .paxCompatible)) ?? false
        paxContentFilter = (try? c.decode(Bool.self, forKey: .paxContentFilter)) ?? false
    }

    public static func decode(_ data: Data) -> ShieldConfig? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(ShieldConfig.self, from: data)
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }
}

public enum ShieldAction: String, Codable { case blocked, allowed, passed }

public struct ShieldDecision: Equatable {
    public var action: ShieldAction
    public var info: MatchInfo?
    /// Why nothing was applied: "off", "paused", "app paused".
    public var note: String?

    public static let pass = ShieldDecision(action: .passed, info: nil, note: nil)

    public init(action: ShieldAction, info: MatchInfo?, note: String?) {
        self.action = action
        self.info = info
        self.note = note
    }
}

public struct QueryLogEntry: Codable, Equatable, Identifiable {
    public var id: UInt64
    public var time: Date
    public var name: String
    public var type: String
    public var app: String?
    public var action: ShieldAction
    public var source: String?
    public var rule: String?
    public var cname: String?
    public var note: String?

    public init(id: UInt64, time: Date, name: String, type: String, app: String?, action: ShieldAction,
                source: String? = nil, rule: String? = nil, cname: String? = nil, note: String? = nil) {
        self.id = id; self.time = time; self.name = name; self.type = type; self.app = app
        self.action = action; self.source = source; self.rule = rule; self.cname = cname; self.note = note
    }
}

public struct CountedName: Codable, Equatable, Identifiable {
    public var name: String
    public var count: Int
    public var id: String { name }
    public init(name: String, count: Int) { self.name = name; self.count = count }
}

/// What the UI and menu bar show.
public struct ShieldStats: Codable, Equatable {
    public var since: Date
    public var day: String
    public var queriesToday = 0
    public var blockedToday = 0
    public var queriesTotal = 0
    public var blockedTotal = 0
    public var cnameBlockedTotal = 0
    public var bypassBlockedTotal = 0
    public var bySource: [String: Int] = [:]
    public var topBlocked: [CountedName] = []
    public var topApps: [CountedName] = []
    public var indexCreatedAt: Date?
    public var indexDomains = 0
    public var mode: String = ""

    public init(since: Date, day: String) {
        self.since = since
        self.day = day
    }

    public var blockedPercentToday: Double { queriesToday == 0 ? 0 : Double(blockedToday) / Double(queriesToday) * 100 }

    public static func decode(_ data: Data) -> ShieldStats? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(ShieldStats.self, from: data)
    }

    public func encoded() -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        return (try? e.encode(self)) ?? Data()
    }

    /// "1.2k", "34k", "1.1M" for the menu bar.
    public static func compact(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000: return "\(n / 1000)k"
        default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }
}

/// Counts and a ring-buffer log, bounded in memory.
public final class ShieldStatsCollector {
    private var stats: ShieldStats
    private var blockedCounts: [String: Int] = [:]
    private var appCounts: [String: Int] = [:]
    private var log: [QueryLogEntry] = []
    private var logStart = 0
    private var nextID: UInt64 = 1
    public let logCapacity: Int
    private let lock = NSLock()
    private let calendar: Calendar

    public init(now: Date = Date(), logCapacity: Int = 5000, calendar: Calendar = .current) {
        self.logCapacity = logCapacity
        self.calendar = calendar
        stats = ShieldStats(since: now, day: ShieldStatsCollector.dayString(now, calendar))
    }

    static func dayString(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func record(name: String, type: String, app: String?, decision: ShieldDecision, keepLog: Bool, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let day = ShieldStatsCollector.dayString(now, calendar)
        if day != stats.day { stats.day = day; stats.queriesToday = 0; stats.blockedToday = 0 }
        stats.queriesToday += 1
        stats.queriesTotal += 1
        if decision.action == .blocked {
            stats.blockedToday += 1
            stats.blockedTotal += 1
            if decision.info?.cnameTarget != nil { stats.cnameBlockedTotal += 1 }
            if decision.info?.source == "doh-policy" { stats.bypassBlockedTotal += 1 }
            if let s = decision.info?.source { stats.bySource[s, default: 0] += 1 }
            blockedCounts[name, default: 0] += 1
            if let a = app { appCounts[a, default: 0] += 1 }
            if blockedCounts.count > 4000 { prune(&blockedCounts, keep: 2000) }
            if appCounts.count > 500 { prune(&appCounts, keep: 250) }
        }
        guard keepLog else { return }
        let e = QueryLogEntry(id: nextID, time: now, name: name, type: type, app: app, action: decision.action,
                              source: decision.info?.source, rule: decision.info?.rule, cname: decision.info?.cnameTarget,
                              note: decision.note)
        nextID += 1
        if log.count < logCapacity { log.append(e) } else { log[logStart] = e; logStart = (logStart + 1) % logCapacity }
    }

    private func prune(_ d: inout [String: Int], keep: Int) {
        let kept = d.sorted { $0.value > $1.value }.prefix(keep)
        d = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    public func snapshot(top: Int = 20) -> ShieldStats {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        s.topBlocked = blockedCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(top).map { CountedName(name: $0.key, count: $0.value) }
        s.topApps = appCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(top).map { CountedName(name: $0.key, count: $0.value) }
        return s
    }

    /// Log entries newer than `afterID`, oldest first.
    public func entries(after afterID: UInt64 = 0, limit: Int = 1000) -> [QueryLogEntry] {
        lock.lock(); defer { lock.unlock() }
        let ordered = Array(log[logStart...]) + Array(log[..<logStart])
        return Array(ordered.filter { $0.id > afterID }.suffix(limit))
    }

    public func clearLog() {
        lock.lock(); defer { lock.unlock() }
        log.removeAll(); logStart = 0
    }

    public func resetStats(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        stats = ShieldStats(since: now, day: ShieldStatsCollector.dayString(now, calendar))
        blockedCounts.removeAll(); appCounts.removeAll()
    }
}

/// Thread-safe decision engine.
public final class ShieldEngine {
    private let lock = NSLock()
    private var config: ShieldConfig
    private var index: ShieldIndex?
    private var matcher: DomainMatcher
    private var policy: EncryptedDNSPolicy
    private var uncloaker: CNAMEUncloaker
    public let stats: ShieldStatsCollector

    public init(config: ShieldConfig = ShieldConfig(), index: ShieldIndex? = nil, stats: ShieldStatsCollector = ShieldStatsCollector()) {
        self.config = config
        self.index = index
        self.stats = stats
        matcher = DomainMatcher(lists: index, user: config.userRules)
        policy = ShieldEngine.makePolicy(config)
        uncloaker = CNAMEUncloaker(useBuiltInTrackers: config.builtInCloakTrackers)
    }

    static func makePolicy(_ c: ShieldConfig) -> EncryptedDNSPolicy {
        // Next to Pax, Shield never interferes with anyone's encrypted DNS (Pax uses DoH itself).
        EncryptedDNSPolicy(mode: c.paxCompatible ? .allow : c.encryptedDNS, blockPrivateRelay: c.paxCompatible ? false : c.blockPrivateRelay,
                           upstreamHosts: c.upstream.hosts, upstreamIPs: c.upstream.ips)
    }

    public var currentConfig: ShieldConfig { lock.lock(); defer { lock.unlock() }; return config }
    public var currentIndex: ShieldIndex? { lock.lock(); defer { lock.unlock() }; return index }

    public func update(config new: ShieldConfig) {
        lock.lock(); defer { lock.unlock() }
        let rulesChanged = new.userRules != config.userRules
        config = new
        if rulesChanged { matcher = DomainMatcher(lists: index, user: new.userRules) }
        policy = ShieldEngine.makePolicy(new)
        uncloaker = CNAMEUncloaker(useBuiltInTrackers: new.builtInCloakTrackers)
    }

    public func update(index new: ShieldIndex?) {
        lock.lock(); defer { lock.unlock() }
        index = new
        matcher = DomainMatcher(lists: new, user: config.userRules)
    }

    private func snapshot() -> (ShieldConfig, DomainMatcher, EncryptedDNSPolicy, CNAMEUncloaker) {
        lock.lock(); defer { lock.unlock() }
        return (config, matcher, policy, uncloaker)
    }

    /// Decision for a lookup before it goes upstream.
    public func decide(name rawName: String, type: String? = nil, app: String? = nil, now: Date = Date()) -> ShieldDecision {
        let (c, m, p, _) = snapshot()
        guard c.enabled else { return ShieldDecision(action: .passed, info: nil, note: "off") }
        if c.isPaused(at: now) { return ShieldDecision(action: .passed, info: nil, note: "paused") }
        if let a = app, c.appPauses.contains(where: { $0.id == a && ($0.until.map { $0 > now } ?? true) }) {
            return ShieldDecision(action: .passed, info: nil, note: "app paused")
        }
        guard let name = DomainName.normalize(rawName) else { return .pass }
        if c.paxCompatible, PaxCompatibility.isProtectedHost(name) {
            return ShieldDecision(action: .passed, info: nil, note: "pax")
        }
        if let s = c.sitePauses.first(where: { ($0.until.map { $0 > now } ?? true) && DomainName.isSubdomain(name, of: $0.domain) }) {
            return ShieldDecision(action: .allowed, info: MatchInfo(source: "site-pause", rule: "@@||\(s.domain)^"), note: "site paused")
        }
        // The user's allowlist beats the bypass policy too.
        let r = m.match(name, type: type)
        if case .allowed(let i) = r, i.source == "allowlist" || i.source == "custom" {
            return ShieldDecision(action: .allowed, info: i, note: nil)
        }
        if case .blocked(let i) = p.queryVerdict(name) { return ShieldDecision(action: .blocked, info: i, note: nil) }
        switch r {
        case .blocked(let i): return ShieldDecision(action: .blocked, info: i, note: nil)
        case .allowed(let i): return ShieldDecision(action: .allowed, info: i, note: nil)
        case .noMatch: return .pass
        }
    }

    /// After the upstream answered: look for a cloaked tracker in the alias chain.
    public func inspect(response: DNSMessage, query name: String, prior: ShieldDecision) -> ShieldDecision {
        let (c, m, _, u) = snapshot()
        guard c.cnameUncloaking, prior.action == .passed, prior.note == nil else { return prior }
        let chain = response.aliasChain(for: name)
        guard !chain.isEmpty else { return prior }
        let res = u.evaluate(query: name, queryResult: .noMatch, chain: chain) { m.match($0) }
        if case .blocked(let info) = res.verdict { return ShieldDecision(action: .blocked, info: info, note: "cname") }
        return prior
    }

    public func flowVerdict(remoteIP: String?, remoteHostname: String?, port: Int, proto: FlowProtocol,
                            app: String?, now: Date = Date()) -> FlowVerdict {
        let (c, m, p, _) = snapshot()
        guard c.enabled, !c.isPaused(at: now) else { return .allow }
        if let a = app, c.appPauses.contains(where: { $0.id == a && ($0.until.map { $0 > now } ?? true) }) { return .allow }
        // Next to Pax the filter only ever drops, and never anything of Pax's.
        if c.paxCompatible, PaxCompatibility.isProtectedIP(remoteIP) || PaxCompatibility.isProtectedHost(remoteHostname) { return .allow }
        let v = p.flowVerdict(remoteIP: remoteIP, remoteHostname: remoteHostname, port: port, proto: proto)
        if case .drop = v { return v }
        // Apps that connect by hostname (URLSession, Network.framework) are checked again
        // here, which also catches answers cached before Shield started.
        if let h = remoteHostname.flatMap({ DomainName.normalize($0) }), !DomainName.isIPAddress(h) {
            if c.sitePauses.contains(where: { ($0.until.map { $0 > now } ?? true) && DomainName.isSubdomain(h, of: $0.domain) }) { return .allow }
            if case .blocked(let i) = m.match(h) { return .drop(reason: "\(i.rule) (\(i.source))") }
        }
        return .allow
    }

    /// Convenience used by the DNS servers: decide, record, and give back a block answer if needed.
    public func handleQuery(_ packet: Data, app: String?, now: Date = Date()) -> (decision: ShieldDecision, question: DNSQuestion?, blockedAnswer: Data?) {
        guard let msg = try? DNSMessage.parse(packet), let q = msg.questions.first else { return (.pass, nil, nil) }
        let d = decide(name: q.name, type: q.typeName, app: app, now: now)
        if d.action == .blocked {
            let c = currentConfig
            return (d, q, DNSMessage.blockedResponse(to: packet, mode: c.blockResponse))
        }
        return (d, q, nil)
    }

    /// Records the final outcome of a query.
    public func record(question q: DNSQuestion, app: String?, decision: ShieldDecision, now: Date = Date()) {
        stats.record(name: q.name, type: q.typeName, app: app, decision: decision, keepLog: currentConfig.logQueries, now: now)
    }
}
