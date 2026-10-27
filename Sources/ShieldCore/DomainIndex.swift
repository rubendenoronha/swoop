// SPDX-License-Identifier: MIT
//
// The compiled, compact form of every DNS rule Swoop Shield applies: a reversed-label trie
// ("com" → "example" → "ads") flattened into a fixed-size node array with a deduplicated
// label pool, plus a Bloom filter for fast misses and a small table of "complex" rules
// (wildcards, regexes, $denyallow/$dnstype) that a trie can't hold. The file is read in
// place (memory-mapped) by the system extension and the local resolver; nothing is
// decoded up front, so a million-domain index loads instantly.
//
// Binary layout (little-endian), version 1:
//   magic "SWSHIDX\0" · u32 version · u32 reserved · f64 createdAt
//   u32 nodeCount · u32 labelPoolBytes · u32 bloomBytes · u32 bloomK · u32 sourceCount
//   u32 complexCount · u32 domainCount
//   sources:  sourceCount × (u16 len, utf8)
//   complex:  complexCount × (u32 len, utf8 "<sourceIndex>\t<canonical rule>")
//   nodes:    nodeCount × 16 bytes (u32 labelOffset, u32 firstChild, u32 childCount,
//                                   u8 labelLen, u8 flags, u8 blockSource, u8 allowSource)
//   labelPool · bloom bits · SHA-256 of everything above (32 bytes)
import Foundation

public struct TrieFlags: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let blockSubtree = TrieFlags(rawValue: 1)
    public static let blockExact = TrieFlags(rawValue: 2)
    public static let allowSubtree = TrieFlags(rawValue: 4)
    public static let allowExact = TrieFlags(rawValue: 8)
    public static let importantBlock = TrieFlags(rawValue: 16)
    public static let importantAllow = TrieFlags(rawValue: 32)

    public var blocks: Bool { !intersection([.blockSubtree, .blockExact]).isEmpty }
    public var allows: Bool { !intersection([.allowSubtree, .allowExact]).isEmpty }
}

public enum DomainIndexError: Error, Equatable, CustomStringConvertible {
    case tooShort, badMagic, unsupportedVersion(UInt32), corrupt(String), checksumMismatch, tooManySources

    public var description: String {
        switch self {
        case .tooShort: return "Index file is truncated"
        case .badMagic: return "Not a Swoop Shield index"
        case .unsupportedVersion(let v): return "Index version \(v) isn't supported"
        case .corrupt(let s): return "Index is corrupt (\(s))"
        case .checksumMismatch: return "Index checksum doesn't match (damaged or tampered with)"
        case .tooManySources: return "More than 255 rule sources"
        }
    }
}

/// Collects DNS rules and writes the binary index.
public struct DomainIndexBuilder {
    public private(set) var sources: [String] = []
    private var sourceIndex: [String: UInt8] = [:]
    private var entries: [String: (flags: UInt8, block: UInt8, allow: UInt8)] = [:]
    private var complex: [(UInt8, DNSRule)] = []
    private var complexSeen: Set<String> = []
    private var disabled: Set<String> = []   // canonical rules switched off by $badfilter

    public init() {}

    public var domainCount: Int { entries.count }
    public var complexCount: Int { complex.count }

    /// Registers a rule source (list id, "custom", "allowlist"). Returns its index.
    @discardableResult
    public mutating func source(_ id: String) throws -> UInt8 {
        if let i = sourceIndex[id] { return i }
        guard sources.count < 255 else { throw DomainIndexError.tooManySources }
        let i = UInt8(sources.count)
        sources.append(id)
        sourceIndex[id] = i
        return i
    }

    /// `$badfilter` lines: call before or after adding; disabled rules are dropped at build.
    public mutating func disable(_ rule: DNSRule) { disabled.insert(rule.canonical) }

    public mutating func add(_ rule: DNSRule, source: String) throws {
        let s = try self.source(source)
        add(rule, sourceIndex: s)
    }

    public mutating func add(_ rule: DNSRule, sourceIndex s: UInt8) {
        if rule.isComplex {
            let key = rule.canonical
            if complexSeen.insert(key).inserted { complex.append((s, rule)) }
            return
        }
        let name = rule.pattern.value
        var f: TrieFlags
        switch (rule.pattern.kind, rule.isException) {
        case (.subtree, false): f = .blockSubtree
        case (.exact, false): f = .blockExact
        case (.subtree, true): f = .allowSubtree
        case (.exact, true): f = .allowExact
        default: return
        }
        if rule.important { f.insert(rule.isException ? .importantAllow : .importantBlock) }
        if var e = entries[name] {
            if rule.isException { if !TrieFlags(rawValue: e.flags).allows { e.allow = s } } else if !TrieFlags(rawValue: e.flags).blocks { e.block = s }
            e.flags |= f.rawValue
            entries[name] = e
        } else {
            entries[name] = (f.rawValue, rule.isException ? 0 : s, rule.isException ? s : 0)
        }
    }

    /// Writes the index. `createdAt` is stored for the UI ("lists compiled 2 h ago").
    public func build(createdAt: Date = Date()) -> Data {
        // Apply $badfilter.
        var live = entries
        if !disabled.isEmpty {
            for name in live.keys {
                let e = live[name]!
                var f = TrieFlags(rawValue: e.flags)
                let imp = f.contains(.importantBlock) || f.contains(.importantAllow)
                for (flag, rule) in [(TrieFlags.blockSubtree, DNSRule(pattern: HostPattern(.subtree, name), important: imp)),
                                     (.blockExact, DNSRule(pattern: HostPattern(.exact, name), important: imp)),
                                     (.allowSubtree, DNSRule(pattern: HostPattern(.subtree, name), isException: true, important: imp)),
                                     (.allowExact, DNSRule(pattern: HostPattern(.exact, name), isException: true, important: imp))] {
                    var plain = rule; plain.important = false
                    if f.contains(flag) && (disabled.contains(rule.canonical) || disabled.contains(plain.canonical)) { f.remove(flag) }
                }
                if !f.blocks { f.remove(.importantBlock) }
                if !f.allows { f.remove(.importantAllow) }
                if f.rawValue == 0 { live[name] = nil } else { live[name] = (f.rawValue, e.block, e.allow) }
            }
        }
        let liveComplex = complex.filter { !disabled.contains($0.1.canonical) }

        // Sort by reversed labels joined with 0x00 so every node's children are contiguous.
        var keyed: [(key: [UInt8], flags: UInt8, block: UInt8, allow: UInt8)] = []
        keyed.reserveCapacity(live.count)
        for (name, e) in live {
            var k: [UInt8] = []
            k.reserveCapacity(name.utf8.count)
            for (i, label) in DomainName.reversedLabels(name).enumerated() {
                if i > 0 { k.append(0) }
                k.append(contentsOf: label.utf8)
            }
            keyed.append((k, e.flags, e.block, e.allow))
        }
        keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }

        var labelOff: [UInt32] = [0], labelLen: [UInt8] = [0], flags: [UInt8] = [0], bsrc: [UInt8] = [0], asrc: [UInt8] = [0]
        var firstChild: [UInt32] = [0], childCount: [UInt32] = [0]
        var pool: [UInt8] = []
        var poolIndex: [[UInt8]: UInt32] = [:]
        var cursor = [Int](repeating: 0, count: keyed.count)
        var queue: [(node: Int, lo: Int, hi: Int)] = [(0, 0, keyed.count)]
        var qi = 0
        while qi < queue.count {
            let (node, lo, hi) = queue[qi]
            qi += 1
            var i = lo
            // Entries that end at this node come first (shorter keys sort first).
            while i < hi && cursor[i] >= keyed[i].key.count {
                if node != 0 {
                    let had = TrieFlags(rawValue: flags[node])
                    let add = TrieFlags(rawValue: keyed[i].flags)
                    if add.blocks && !had.blocks { bsrc[node] = keyed[i].block }
                    if add.allows && !had.allows { asrc[node] = keyed[i].allow }
                    flags[node] |= keyed[i].flags
                }
                i += 1
            }
            let first = labelOff.count
            var count = 0
            while i < hi {
                let k = keyed[i].key
                let start = cursor[i]
                var end = start
                while end < k.count && k[end] != 0 { end += 1 }
                let label = Array(k[start..<end])
                var j = i + 1
                while j < hi {
                    let kj = keyed[j].key
                    let sj = cursor[j]
                    var ej = sj
                    while ej < kj.count && kj[ej] != 0 { ej += 1 }
                    if ej - sj != label.count || !kj[sj..<ej].elementsEqual(label) { break }
                    j += 1
                }
                for m in i..<j {
                    var e = cursor[m] + label.count
                    if e < keyed[m].key.count { e += 1 }   // skip the 0x00 separator
                    cursor[m] = e
                }
                let off: UInt32
                if let o = poolIndex[label] { off = o } else {
                    off = UInt32(pool.count)
                    pool.append(contentsOf: label)
                    poolIndex[label] = off
                }
                labelOff.append(off); labelLen.append(UInt8(min(255, label.count))); flags.append(0)
                bsrc.append(0); asrc.append(0); firstChild.append(0); childCount.append(0)
                queue.append((labelOff.count - 1, i, j))
                count += 1
                i = j
            }
            firstChild[node] = UInt32(first)
            childCount[node] = UInt32(count)
        }

        // Bloom filter over every listed name.
        var bloom = BloomFilter(capacity: max(1, live.count), falsePositiveRate: 0.01)
        for name in live.keys { bloom.insert(name) }

        var out = Data()
        func u8(_ v: UInt8) { out.append(v) }
        func u16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { out.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        func u64(_ v: UInt64) { for s in stride(from: 0, to: 64, by: 8) { out.append(UInt8((v >> UInt64(s)) & 0xFF)) } }
        out.append(contentsOf: Array("SWSHIDX".utf8) + [0])
        u32(ShieldIndex.version); u32(0)
        u64(createdAt.timeIntervalSince1970.bitPattern)
        u32(UInt32(labelOff.count)); u32(UInt32(pool.count)); u32(UInt32(bloom.bits.count)); u32(UInt32(bloom.hashCount))
        u32(UInt32(sources.count)); u32(UInt32(liveComplex.count)); u32(UInt32(live.count))
        for s in sources { let b = Array(s.utf8.prefix(65535)); u16(UInt16(b.count)); out.append(contentsOf: b) }
        for (s, r) in liveComplex { let b = Array("\(s)\t\(r.canonical)".utf8); u32(UInt32(b.count)); out.append(contentsOf: b) }
        out.reserveCapacity(out.count + labelOff.count * 16 + pool.count + bloom.bits.count + 32)
        for n in 0..<labelOff.count {
            u32(labelOff[n]); u32(firstChild[n]); u32(childCount[n])
            u8(labelLen[n]); u8(flags[n]); u8(bsrc[n]); u8(asrc[n])
        }
        out.append(contentsOf: pool)
        out.append(contentsOf: bloom.bits)
        out.append(contentsOf: SHA256.hash(out).bytes)
        return out
    }
}

/// What the trie found for one hostname.
public struct IndexMatch: Equatable {
    public var flags: TrieFlags = []
    public var blockSource: String?
    public var allowSource: String?
    /// The listed name that matched ("example.com" for a query of "ads.example.com").
    public var blockedBy: String?
    public var allowedBy: String?
    public var blockRule: String?
    public var allowRule: String?

    public var isEmpty: Bool { !flags.blocks && !flags.allows }
}

/// Read-only view over a compiled index.
public final class ShieldIndex {
    public static let version: UInt32 = 1
    public let data: Data
    public let createdAt: Date
    public let sources: [String]
    public let domainCount: Int
    public let nodeCount: Int
    public let complexRules: [(source: String, rule: DNSRule)]
    private let nodesOffset: Int
    private let poolOffset: Int
    private let bloom: BloomFilter
    private let wildcardBuckets: [String: [Int]]   // literal domain suffix → complex rule indexes
    private let unbucketed: [Int]
    /// Longest literal run of each wildcard rule: a cheap substring pre-check before the glob.
    private let literals: [Int: [UInt8]]
    private let regexes: [Int: NSRegularExpression]
    /// All regex rules OR-ed together: one pass decides whether any of them can match.
    private let combinedRegex: NSRegularExpression?

    /// Validates magic, version, bounds and the trailing SHA-256 unless `verifyChecksum` is false.
    public init(data: Data, verifyChecksum: Bool = true) throws {
        self.data = data
        let b = [UInt8](data.prefix(64))
        guard data.count >= 52 + 32 else { throw DomainIndexError.tooShort }
        guard Array(b[0..<8]) == Array("SWSHIDX".utf8) + [0] else { throw DomainIndexError.badMagic }
        func r32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        let v = r32(8)
        guard v == ShieldIndex.version else { throw DomainIndexError.unsupportedVersion(v) }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(b[16 + i]) << UInt64(8 * i) }
        createdAt = Date(timeIntervalSince1970: Double(bitPattern: bits))
        let nodeCount = Int(r32(24)), poolBytes = Int(r32(28)), bloomBytes = Int(r32(32)), bloomK = Int(r32(36))
        let sourceCount = Int(r32(40)), complexCount = Int(r32(44))
        domainCount = Int(r32(48))
        self.nodeCount = nodeCount
        if verifyChecksum {
            let body = data.prefix(data.count - 32)
            guard SHA256.hash(body).bytes == [UInt8](data.suffix(32)) else { throw DomainIndexError.checksumMismatch }
        }
        var o = 52
        let all = data
        func byte(_ i: Int) -> UInt8 { all[all.startIndex + i] }
        func read16(_ i: Int) -> Int { Int(byte(i)) | Int(byte(i + 1)) << 8 }
        func read32(_ i: Int) -> Int { Int(byte(i)) | Int(byte(i + 1)) << 8 | Int(byte(i + 2)) << 16 | Int(byte(i + 3)) << 24 }
        func str(_ i: Int, _ n: Int) throws -> String {
            guard i + n <= data.count - 32 else { throw DomainIndexError.corrupt("string out of bounds") }
            return String(decoding: all[(all.startIndex + i)..<(all.startIndex + i + n)], as: UTF8.self)
        }
        var srcs: [String] = []
        for _ in 0..<sourceCount {
            guard o + 2 <= data.count else { throw DomainIndexError.corrupt("sources") }
            let n = read16(o); o += 2
            srcs.append(try str(o, n)); o += n
        }
        sources = srcs
        var cx: [(String, DNSRule)] = []
        for _ in 0..<complexCount {
            guard o + 4 <= data.count else { throw DomainIndexError.corrupt("complex rules") }
            let n = read32(o); o += 4
            let line = try str(o, n); o += n
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let si = Int(parts[0]), si < srcs.count else { continue }
            if let rule = RuleParser.parseLine(String(parts[1]), options: .dnsList).dns { cx.append((srcs[si], rule)) }
        }
        complexRules = cx
        nodesOffset = o
        poolOffset = o + nodeCount * 16
        let bloomOffset = poolOffset + poolBytes
        guard nodeCount >= 1, bloomOffset + bloomBytes + 32 == data.count else { throw DomainIndexError.corrupt("section sizes") }
        bloom = BloomFilter(bits: [UInt8](all[(all.startIndex + bloomOffset)..<(all.startIndex + bloomOffset + bloomBytes)]), hashCount: bloomK)

        var buckets: [String: [Int]] = [:]
        var rest: [Int] = []
        var lits: [Int: [UInt8]] = [:]
        var res: [Int: NSRegularExpression] = [:]
        var alternatives: [String] = []
        for (i, c) in cx.enumerated() {
            if c.1.pattern.kind == .wildcard {
                let runs = c.1.pattern.value.split(separator: "*").map(String.init)
                if let best = runs.max(by: { $0.utf8.count < $1.utf8.count }), best.utf8.count >= 3 { lits[i] = Array(best.utf8) }
            } else if c.1.pattern.kind == .regex, let re = try? NSRegularExpression(pattern: c.1.pattern.value, options: [.caseInsensitive]) {
                res[i] = re
                alternatives.append("(?:\(c.1.pattern.value))")
            }
            if c.1.pattern.kind == .wildcard, let lit = ShieldIndex.literalSuffix(of: c.1.pattern.value) {
                buckets[lit, default: []].append(i)
            } else if c.1.pattern.kind == .subtree || c.1.pattern.kind == .exact {
                buckets[c.1.pattern.value, default: []].append(i)
            } else {
                rest.append(i)
            }
        }
        wildcardBuckets = buckets
        unbucketed = rest
        literals = lits
        regexes = res
        combinedRegex = alternatives.isEmpty ? nil : try? NSRegularExpression(pattern: alternatives.joined(separator: "|"), options: [.caseInsensitive])
    }

    public convenience init(contentsOf url: URL, verifyChecksum: Bool = true) throws {
        try self.init(data: try Data(contentsOf: url, options: .alwaysMapped), verifyChecksum: verifyChecksum)
    }

    /// "ad*.example.com" → "example.com"; "*.tracker.net" → "tracker.net"; nil when the
    /// literal tail isn't a whole domain.
    static func literalSuffix(of glob: String) -> String? {
        guard let star = glob.lastIndex(of: "*") else { return glob }
        var tail = glob[glob.index(after: star)...]
        guard tail.hasPrefix(".") else { return nil }
        tail = tail.dropFirst()
        guard tail.contains("."), DomainName.isValidHostname(String(tail)) else { return nil }
        return String(tail)
    }

    // MARK: lookup

    /// Trie (+ Bloom) lookup for `name` (already normalised).
    public func lookup(_ name: String) -> IndexMatch {
        var result = IndexMatch()
        let suffixes = DomainName.suffixes(name)
        if !suffixes.contains(where: { bloom.mightContain($0) }) { return result }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            @inline(__always) func u32(_ o: Int) -> Int { Int(p[o]) | Int(p[o + 1]) << 8 | Int(p[o + 2]) << 16 | Int(p[o + 3]) << 24 }
            var node = 0
            let labels = DomainName.reversedLabels(name)
            for (depth, label) in labels.enumerated() {
                let base = nodesOffset + node * 16
                let first = u32(base + 4), count = u32(base + 8)
                guard count > 0 else { break }
                // Binary search the children by label bytes.
                let target = Array(label.utf8)
                var lo = 0, hi = count - 1, found = -1
                while lo <= hi {
                    let mid = (lo + hi) >> 1
                    let nb = nodesOffset + (first + mid) * 16
                    let off = poolOffset + u32(nb), len = Int(p[nb + 12])
                    var cmp = 0
                    let n = min(len, target.count)
                    var k = 0
                    while k < n {
                        let a = p[off + k], bb = target[k]
                        if a != bb { cmp = a < bb ? -1 : 1; break }
                        k += 1
                    }
                    if cmp == 0 { cmp = len == target.count ? 0 : (len < target.count ? -1 : 1) }
                    if cmp == 0 { found = first + mid; break }
                    if cmp < 0 { lo = mid + 1 } else { hi = mid - 1 }
                }
                guard found >= 0 else { break }
                node = found
                let nb = nodesOffset + node * 16
                let f = TrieFlags(rawValue: p[nb + 13])
                if f.rawValue == 0 { continue }
                let isFull = depth == labels.count - 1
                let listed = String(suffixes[labels.count - 1 - depth])
                let blockHere = f.contains(.blockSubtree) || (isFull && f.contains(.blockExact))
                let allowHere = f.contains(.allowSubtree) || (isFull && f.contains(.allowExact))
                if blockHere {
                    result.flags.insert(f.contains(.blockSubtree) ? .blockSubtree : .blockExact)
                    if f.contains(.importantBlock) { result.flags.insert(.importantBlock) }
                    let si = Int(p[nb + 14])
                    result.blockSource = si < sources.count ? sources[si] : nil
                    result.blockedBy = listed
                    result.blockRule = f.contains(.blockSubtree) ? "||\(listed)^" : "|\(listed)^"
                }
                if allowHere {
                    result.flags.insert(f.contains(.allowSubtree) ? .allowSubtree : .allowExact)
                    if f.contains(.importantAllow) { result.flags.insert(.importantAllow) }
                    let si = Int(p[nb + 15])
                    result.allowSource = si < sources.count ? sources[si] : nil
                    result.allowedBy = listed
                    result.allowRule = "@@||\(listed)^"
                }
            }
        }
        return result
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard n > 0, hay.count >= n else { return n == 0 }
        let first = needle[0]
        var i = 0
        let last = hay.count - n
        while i <= last {
            if hay[i] == first {
                var k = 1
                while k < n && hay[i + k] == needle[k] { k += 1 }
                if k == n { return true }
            }
            i += 1
        }
        return false
    }

    /// Complex rules (wildcards, regex, $denyallow, $dnstype) that apply to `name`.
    public func complexMatches(_ name: String, type: String?) -> [(source: String, rule: DNSRule)] {
        guard !complexRules.isEmpty else { return [] }
        var candidates: [Int] = []
        for s in DomainName.suffixes(name) { if let b = wildcardBuckets[String(s)] { candidates += b } }
        var regexMayMatch: Bool?
        let bytes = Array(name.utf8)
        var out: [(String, DNSRule)] = []
        for i in candidates + unbucketed {
            let (src, rule) = complexRules[i]
            switch rule.pattern.kind {
            case .wildcard:
                if let lit = literals[i], !ShieldIndex.contains(bytes, lit) { continue }
                let g = rule.pattern.value
                // "||ad*.example.com^" also covers subdomains of a match ("x.ad1.example.com").
                guard Glob.match(g, name) || Glob.match("*." + g, name) else { continue }
            case .regex:
                if regexMayMatch == nil {
                    regexMayMatch = combinedRegex.map { $0.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)) != nil } ?? true
                }
                guard regexMayMatch == true, let re = regexes[i],
                      re.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)) != nil else { continue }
            case .subtree: guard DomainName.isSubdomain(name, of: rule.pattern.value) else { continue }
            case .exact: guard name == rule.pattern.value else { continue }
            }
            guard rule.applies(toType: type) else { continue }
            if !rule.denyAllow.isEmpty && rule.denyAllow.contains(where: { DomainName.isSubdomain(name, of: $0) }) { continue }
            out.append((src, rule))
        }
        return out
    }
}
