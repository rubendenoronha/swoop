// SPDX-License-Identifier: MIT
//
// Just enough of the DNS wire format (RFC 1035, 3596, 6891, 8914, 9460) for a filtering
// proxy: read the question, read answer records (A, AAAA, CNAME, HTTPS/SVCB target names),
// and synthesise blocked answers with an Extended DNS Error ("Blocked", code 15).
import Foundation

public enum DNSRecordType: UInt16 {
    case a = 1, ns = 2, cname = 5, soa = 6, ptr = 12, mx = 15, txt = 16, aaaa = 28, srv = 33, opt = 41,
         svcb = 64, https = 65, any = 255

    public static func name(_ v: UInt16) -> String {
        switch DNSRecordType(rawValue: v) {
        case .a: return "A"
        case .ns: return "NS"
        case .cname: return "CNAME"
        case .soa: return "SOA"
        case .ptr: return "PTR"
        case .mx: return "MX"
        case .txt: return "TXT"
        case .aaaa: return "AAAA"
        case .srv: return "SRV"
        case .opt: return "OPT"
        case .svcb: return "SVCB"
        case .https: return "HTTPS"
        case .any: return "ANY"
        case nil: return "TYPE\(v)"
        }
    }
}

public enum DNSRCode: UInt8 { case noError = 0, formErr = 1, servFail = 2, nxDomain = 3, notImp = 4, refused = 5 }

/// How blocked names are answered.
public enum BlockResponse: String, Codable, CaseIterable {
    /// "No such domain" (fast, apps stop retrying). Default.
    case nxdomain
    /// 0.0.0.0 / :: for A/AAAA, empty answer for other types (what hosts files do).
    case nullIP
    /// REFUSED.
    case refused

    public var title: String {
        switch self {
        case .nxdomain: return "No such domain (NXDOMAIN)"
        case .nullIP: return "Unspecified address (0.0.0.0 / ::)"
        case .refused: return "Refused"
        }
    }
}

public struct DNSQuestion: Equatable {
    public var name: String
    public var type: UInt16
    public var qclass: UInt16
    public var typeName: String { DNSRecordType.name(type) }
}

public struct DNSRecord: Equatable {
    public var name: String
    public var type: UInt16
    public var ttl: UInt32
    /// Decoded data for the types Shield cares about.
    public var target: String?      // CNAME target, HTTPS/SVCB TargetName
    public var address: String?     // A / AAAA
}

public struct DNSMessage: Equatable {
    public var id: UInt16
    public var flags: UInt16
    public var questions: [DNSQuestion]
    public var answers: [DNSRecord]
    public var hasEDNS: Bool

    public var isResponse: Bool { flags & 0x8000 != 0 }
    public var rcode: UInt8 { UInt8(flags & 0x000F) }

    public enum ParseError: Error { case truncated, badName, pointerLoop }

    public static func parse(_ data: Data) throws -> DNSMessage {
        let b = [UInt8](data)
        guard b.count >= 12 else { throw ParseError.truncated }
        func u16(_ o: Int) throws -> UInt16 {
            guard o + 1 < b.count else { throw ParseError.truncated }
            return UInt16(b[o]) << 8 | UInt16(b[o + 1])
        }
        func u32(_ o: Int) throws -> UInt32 { UInt32(try u16(o)) << 16 | UInt32(try u16(o + 2)) }
        let id = try u16(0), flags = try u16(2)
        let qd = Int(try u16(4)), an = Int(try u16(6)), ns = Int(try u16(8)), ar = Int(try u16(10))
        var o = 12
        var qs: [DNSQuestion] = []
        for _ in 0..<qd {
            let (name, next) = try readName(b, o)
            o = next
            qs.append(DNSQuestion(name: name, type: try u16(o), qclass: try u16(o + 2)))
            o += 4
        }
        var answers: [DNSRecord] = []
        var edns = false
        for section in 0..<3 {
            let count = section == 0 ? an : (section == 1 ? ns : ar)
            for _ in 0..<count {
                let (name, next) = try readName(b, o)
                o = next
                let type = try u16(o), ttl = try u32(o + 4), rdlen = Int(try u16(o + 8))
                let rd = o + 10
                guard rd + rdlen <= b.count else { throw ParseError.truncated }
                if section == 2 && type == DNSRecordType.opt.rawValue { edns = true }
                if section == 0 {
                    var rec = DNSRecord(name: name, type: type, ttl: ttl, target: nil, address: nil)
                    switch DNSRecordType(rawValue: type) {
                    case .cname: rec.target = try readName(b, rd).0
                    case .a where rdlen == 4: rec.address = IPAddress.v4(Array(b[rd..<rd + 4])).description
                    case .aaaa where rdlen == 16: rec.address = IPAddress.v6(Array(b[rd..<rd + 16])).description
                    case .https, .svcb:
                        // SvcPriority (u16) then TargetName (uncompressed per RFC 9460, but tolerate pointers).
                        if rdlen >= 3 { let t = try readName(b, rd + 2).0; rec.target = t.isEmpty ? nil : t }
                    default: break
                    }
                    answers.append(rec)
                }
                o = rd + rdlen
            }
        }
        return DNSMessage(id: id, flags: flags, questions: qs, answers: answers, hasEDNS: edns)
    }

    /// Reads a possibly compressed name at `o`; returns (lowercased name without trailing dot, offset after it).
    static func readName(_ b: [UInt8], _ start: Int) throws -> (String, Int) {
        var labels: [String] = []
        var o = start
        var end: Int?
        var jumps = 0
        while true {
            guard o < b.count else { throw ParseError.truncated }
            let len = Int(b[o])
            if len == 0 { o += 1; break }
            if len & 0xC0 == 0xC0 {
                guard o + 1 < b.count else { throw ParseError.truncated }
                if end == nil { end = o + 2 }
                o = (len & 0x3F) << 8 | Int(b[o + 1])
                jumps += 1
                if jumps > 32 { throw ParseError.pointerLoop }
                continue
            }
            guard len <= 63, o + 1 + len <= b.count else { throw ParseError.badName }
            labels.append(String(decoding: b[(o + 1)..<(o + 1 + len)], as: UTF8.self).lowercased())
            o += 1 + len
            if labels.count > 127 { throw ParseError.badName }
        }
        return (labels.joined(separator: "."), end ?? o)
    }

    /// The CNAME (and HTTPS/SVCB alias) chain for `qname`, in resolution order, excluding qname.
    public func aliasChain(for qname: String, limit: Int = 16) -> [String] {
        var chain: [String] = []
        var current = qname.lowercased()
        var seen: Set<String> = [current]
        while chain.count < limit {
            guard let next = answers.first(where: { $0.name == current && ($0.type == DNSRecordType.cname.rawValue) })?.target
                    ?? answers.first(where: { $0.name == current && ($0.type == DNSRecordType.https.rawValue || $0.type == DNSRecordType.svcb.rawValue) && $0.target != nil && $0.target != current })?.target,
                  seen.insert(next).inserted else { break }
            chain.append(next)
            current = next
        }
        return chain
    }

    public var addresses: [String] { answers.compactMap { $0.address } }

    // MARK: building

    /// Encodes a name (no compression).
    static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") where !label.isEmpty {
            let u = Array(label.utf8.prefix(63))
            out.append(UInt8(u.count))
            out.append(contentsOf: u)
        }
        out.append(0)
        return out
    }

    /// A query for tests and for the resolver's self-check.
    public static func makeQuery(id: UInt16, name: String, type: UInt16, edns: Bool = false) -> Data {
        var out: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, edns ? 1 : 0]
        out += encodeName(name)
        out += [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        if edns { out += [0, 0, 41, 0x10, 0x00, 0, 0, 0, 0, 0, 0] }
        return Data(out)
    }

    /// Answers `query` as blocked without contacting any server. Copies the ID and question,
    /// sets QR/RA, keeps RD, and adds an OPT record with Extended DNS Error 15 ("Blocked")
    /// when the client used EDNS.
    public static func blockedResponse(to query: Data, mode: BlockResponse, ttl: UInt32 = 60,
                                       extraText: String = "Blocked by Swoop Shield") -> Data? {
        guard let q = try? parse(query), let question = q.questions.first else { return nil }
        let b = [UInt8](query)
        // Question section bytes as sent (keeps the client's case for 0x20 randomisation).
        var qEnd = 12
        do {
            let (_, next) = try readName(b, 12)
            qEnd = next + 4
        } catch { return nil }
        guard qEnd <= b.count else { return nil }
        var rcode: UInt16 = 0
        var answers: [UInt8] = []
        var anCount: UInt16 = 0
        switch mode {
        case .nxdomain: rcode = UInt16(DNSRCode.nxDomain.rawValue)
        case .refused: rcode = UInt16(DNSRCode.refused.rawValue)
        case .nullIP:
            if question.type == DNSRecordType.a.rawValue || question.type == DNSRecordType.aaaa.rawValue {
                let isA = question.type == DNSRecordType.a.rawValue
                answers += [0xC0, 0x0C]   // pointer to the question name
                answers += [UInt8(question.type >> 8), UInt8(question.type & 0xFF), 0, 1]
                answers += [UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF)]
                let len = isA ? 4 : 16
                answers += [0, UInt8(len)] + [UInt8](repeating: 0, count: len)
                anCount = 1
            }
        }
        let rd = q.flags & 0x0100
        let flags: UInt16 = 0x8000 | rd | 0x0080 | rcode
        var out: [UInt8] = [b[0], b[1], UInt8(flags >> 8), UInt8(flags & 0xFF), 0, 1,
                            UInt8(anCount >> 8), UInt8(anCount & 0xFF), 0, 0, 0, q.hasEDNS ? 1 : 0]
        out += b[12..<qEnd]
        out += answers
        if q.hasEDNS {
            // OPT: root name, type 41, UDP size 1232, ext-rcode/version/flags 0, RDATA = EDE option.
            let text = Array(extraText.utf8.prefix(200))
            let optLen = 2 + text.count
            var rdata: [UInt8] = [0, 15, UInt8(optLen >> 8), UInt8(optLen & 0xFF), 0, 15]
            rdata += text
            out += [0, 0, 41, 0x04, 0xD0, 0, 0, 0, 0, UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)]
            out += rdata
        }
        return Data(out)
    }

    /// SERVFAIL for a query (upstream unreachable).
    public static func servFail(to query: Data) -> Data? {
        let b = [UInt8](query)
        guard b.count >= 12, let q = try? parse(query) else { return nil }
        guard let (_, next) = try? readName(b, 12), next + 4 <= b.count else { return nil }
        let flags: UInt16 = 0x8000 | (q.flags & 0x0100) | 0x0080 | UInt16(DNSRCode.servFail.rawValue)
        var out: [UInt8] = [b[0], b[1], UInt8(flags >> 8), UInt8(flags & 0xFF), 0, q.questions.isEmpty ? 0 : 1, 0, 0, 0, 0, 0, 0]
        out += b[12..<(next + 4)]
        return Data(out)
    }
}
