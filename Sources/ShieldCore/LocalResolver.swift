// SPDX-License-Identifier: MIT
//
// Shield's fallback when the system extension isn't approved: a small filtering DNS
// forwarder on 127.0.0.1:53 (UDP + TCP). Plain POSIX sockets so the same code runs in
// the macOS launchd daemon and in the Linux test suite. Upstreams: plain DNS servers or
// DNS over HTTPS (bootstrapped by IP, so it never has to resolve itself through itself).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if os(Linux)
private let sockDgram = Int32(SOCK_DGRAM.rawValue)
private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
private let sockDgram = SOCK_DGRAM
private let sockStream = SOCK_STREAM
#endif

/// An IPv4/IPv6 socket address built from text.
public struct SocketAddress: CustomStringConvertible {
    public var storage = sockaddr_storage()
    public var length: socklen_t = 0
    public let host: String
    public let port: UInt16

    public init?(host: String, port: UInt16) {
        self.host = host
        self.port = port
        if inet_pton(AF_INET, host, &storage) == 1 {
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            _ = inet_pton(AF_INET, host, &a.sin_addr)
            withUnsafeBytes(of: &a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        } else {
            var a = sockaddr_in6()
            guard inet_pton(AF_INET6, host, &a.sin6_addr) == 1 else { return nil }
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            storage = sockaddr_storage()
            withUnsafeBytes(of: &a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        }
        #if os(macOS)
        withUnsafeMutableBytes(of: &storage) { $0[0] = UInt8(length) }
        #endif
    }

    /// "1.2.3.4:53", "[::1]:5353", "9.9.9.9" (port 53).
    public init?(_ text: String, defaultPort: UInt16 = 53) {
        var h = text, p = defaultPort
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            h = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let v = UInt16(rest.dropFirst()) { p = v }
        } else if text.filter({ $0 == ":" }).count == 1, let c = text.firstIndex(of: ":") {
            h = String(text[..<c])
            guard let v = UInt16(text[text.index(after: c)...]) else { return nil }
            p = v
        }
        self.init(host: h, port: p)
    }

    public var family: Int32 { Int32(storage.ss_family) }
    public var description: String { family == AF_INET6 ? "[\(host)]:\(port)" : "\(host):\(port)" }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var s = storage
        return withUnsafePointer(to: &s) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) } }
    }
}

public enum UpstreamTransport {
    case udp(SocketAddress)
    case doh(url: URL, bootstrap: [String])
}

/// Decides, forwards and uncloaks one query at a time (thread-safe; call from many threads).
public final class DNSForwarder {
    public let engine: ShieldEngine
    public var upstreams: [UpstreamTransport]
    public var timeout: TimeInterval
    private let session: URLSession

    public init(engine: ShieldEngine, upstreams: [UpstreamTransport], timeout: TimeInterval = 2.5) {
        self.engine = engine
        self.upstreams = upstreams
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpAdditionalHeaders = ["Accept": "application/dns-message"]
        session = URLSession(configuration: cfg)
    }

    /// Upstreams from the Shield config. `.system` uses `systemServers` (the servers macOS
    /// had before Shield took over, saved at install time).
    public static func transports(for upstream: Upstream, systemServers: [String]) -> [UpstreamTransport] {
        switch upstream {
        case .system: return systemServers.compactMap { SocketAddress($0) }.map { .udp($0) }
        case .servers(let s): return s.compactMap { SocketAddress($0) }.map { .udp($0) }
        case .doh(let url, let boot):
            guard let u = URL(string: url) else { return [] }
            return [.doh(url: u, bootstrap: boot)] + systemServers.compactMap { SocketAddress($0) }.map { .udp($0) }
        }
    }

    /// Decide → (answer locally | forward) → uncloak → record. `via` overrides `upstreams`
    /// for this query (the system extension forwards to the server the app was asking).
    public func resolve(_ packet: Data, app: String? = nil, tcp: Bool = false, via: [UpstreamTransport]? = nil) -> Data? {
        let upstreams = via ?? self.upstreams
        let (decision, question, blocked) = engine.handleQuery(packet, app: app)
        guard let q = question else { return DNSMessage.servFail(to: packet) }
        if let b = blocked {
            engine.record(question: q, app: app, decision: decision)
            return b
        }
        // DoH bootstrap: answer the DoH server's own name from its configured IPs.
        for case .doh(let url, let boot) in upstreams where url.host?.lowercased() == q.name && !boot.isEmpty {
            if let a = DNSMessage.addressResponse(to: packet, addresses: boot) {
                engine.record(question: q, app: app, decision: decision)
                return a
            }
        }
        var answer: Data?
        for u in upstreams {
            switch u {
            case .udp(let addr):
                // UDP first; TCP only when the answer came back truncated (TC) for a TCP client.
                answer = DNSForwarder.queryUDP(packet, addr, timeout)
                if tcp, let a = answer, a.count > 2, a[a.startIndex + 2] & 0x02 != 0 {
                    answer = DNSForwarder.queryTCP(packet, addr, timeout) ?? a
                }
            case .doh(let url, _): answer = queryDoH(packet, url)
            }
            if let a = answer, let m = try? DNSMessage.parse(a), m.id == (try? DNSMessage.parse(packet))?.id,
               m.questions.first?.name == q.name { break }
            answer = nil
        }
        guard let a = answer else {
            engine.record(question: q, app: app, decision: ShieldDecision(action: decision.action, info: decision.info, note: "upstream failed"))
            return DNSMessage.servFail(to: packet)
        }
        var final = decision
        if let m = try? DNSMessage.parse(a) {
            final = engine.inspect(response: m, query: q.name, prior: decision)
        }
        engine.record(question: q, app: app, decision: final)
        if final.action == .blocked {
            return DNSMessage.blockedResponse(to: packet, mode: engine.currentConfig.blockResponse)
        }
        return a
    }

    // MARK: upstream transports

    public static func queryUDP(_ packet: Data, _ addr: SocketAddress, _ timeout: TimeInterval) -> Data? {
        let fd = socket(addr.family, sockDgram, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let ok = addr.withSockaddr { connect(fd, $0, $1) } == 0
        guard ok else { return nil }
        let sent = packet.withUnsafeBytes { send(fd, $0.baseAddress, packet.count, 0) }
        guard sent == packet.count else { return nil }
        guard waitReadable(fd, timeout) else { return nil }
        var buf = [UInt8](repeating: 0, count: 65_535)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        return Data(buf[0..<n])
    }

    public static func queryTCP(_ packet: Data, _ addr: SocketAddress, _ timeout: TimeInterval) -> Data? {
        let fd = socket(addr.family, sockStream, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard addr.withSockaddr({ connect(fd, $0, $1) }) == 0 else { return nil }
        var framed = Data([UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        framed.append(packet)
        guard writeAll(fd, framed) else { return nil }
        guard let lenBytes = readExactly(fd, 2, timeout) else { return nil }
        let len = Int(lenBytes[0]) << 8 | Int(lenBytes[1])
        return readExactly(fd, len, timeout).map { Data($0) }
    }

    func queryDoH(_ packet: Data, _ url: URL) -> Data? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = packet
        req.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        session.dataTask(with: req) { data, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200 { box.data = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return box.data
    }

    final class ResultBox: @unchecked Sendable { var data: Data? }

    static func waitReadable(_ fd: Int32, _ timeout: TimeInterval) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, Int32(timeout * 1000)) > 0 && (p.revents & Int16(POLLIN)) != 0
    }

    static func writeAll(_ fd: Int32, _ d: Data) -> Bool {
        var off = 0
        while off < d.count {
            let n = d.withUnsafeBytes { send(fd, $0.baseAddress! + off, d.count - off, 0) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    static func readExactly(_ fd: Int32, _ count: Int, _ timeout: TimeInterval) -> [UInt8]? {
        var out = [UInt8](); out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: max(1, count))
        while out.count < count {
            guard waitReadable(fd, timeout) else { return nil }
            let n = recv(fd, &buf, count - out.count, 0)
            if n <= 0 { return nil }
            out += buf[0..<n]
        }
        return out
    }
}

/// UDP + TCP listener. `start()` returns immediately; requests are handled concurrently.
public final class LocalDNSServer {
    public let forwarder: DNSForwarder
    private var fds: [(fd: Int32, tcp: Bool)] = []
    private var running = false
    private let queue = DispatchQueue(label: "swoop.shield.dns", attributes: .concurrent)
    private let limiter = DispatchSemaphore(value: 64)

    public init(forwarder: DNSForwarder) { self.forwarder = forwarder }

    public enum ServerError: Error, CustomStringConvertible {
        case badAddress(String), socket(String, Int32)
        public var description: String {
            switch self {
            case .badAddress(let a): return "Can't listen on \(a)"
            case .socket(let what, let e): return "\(what) failed: \(String(cString: strerror(e)))"
            }
        }
    }

    /// Binds UDP and TCP on `address` ("127.0.0.1:53"). Port 0 picks a free port; returns it.
    @discardableResult
    public func listen(_ address: String) throws -> UInt16 {
        guard let addr = SocketAddress(address) else { throw ServerError.badAddress(address) }
        let u = socket(addr.family, sockDgram, 0)
        guard u >= 0 else { throw ServerError.socket("socket", errno) }
        var one: Int32 = 1
        setsockopt(u, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard addr.withSockaddr({ bind(u, $0, $1) }) == 0 else { let e = errno; close(u); throw ServerError.socket("bind \(address)", e) }
        let port = boundPort(u)
        guard let tcpAddr = SocketAddress(host: addr.host, port: port) else { throw ServerError.badAddress(address) }
        let t = socket(addr.family, sockStream, 0)
        guard t >= 0 else { throw ServerError.socket("socket", errno) }
        setsockopt(t, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard tcpAddr.withSockaddr({ bind(t, $0, $1) }) == 0, Glibc_listen(t, 32) == 0 else {
            let e = errno; close(t); close(u); throw ServerError.socket("bind/listen tcp \(address)", e)
        }
        fds.append((u, false)); fds.append((t, true))
        return port
    }

    /// Adopts already-bound sockets (launchd socket activation).
    public func adopt(udp: [Int32], tcp: [Int32]) {
        for f in udp { fds.append((f, false)) }
        for f in tcp { fds.append((f, true)) }
    }

    public func start() {
        running = true
        for (fd, tcp) in fds {
            let t = Thread { [weak self] in tcp ? self?.acceptLoop(fd) : self?.udpLoop(fd) }
            t.name = "swoop-dns-\(tcp ? "tcp" : "udp")-\(fd)"
            t.start()
        }
    }

    public func stop() {
        running = false
        for (fd, _) in fds { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
        fds.removeAll()
    }

    private func boundPort(_ fd: Int32) -> UInt16 {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        if Int32(ss.ss_family) == AF_INET {
            return withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
        }
        return withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
    }

    private func udpLoop(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while running {
            guard DNSForwarder.waitReadable(fd, 1) else { continue }
            var ss = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &ss) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 12 else { continue }
            let packet = Data(buf[0..<n])
            let from = ss, fromLen = len
            limiter.wait()
            queue.async { [weak self] in
                defer { self?.limiter.signal() }
                guard let self = self, var resp = self.forwarder.resolve(packet) else { return }
                if resp.count > 1232 { resp = LocalDNSServer.truncated(resp) }
                var to = from
                _ = resp.withUnsafeBytes { b in
                    withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, resp.count, 0, $0, fromLen) } }
                }
            }
        }
    }

    /// Over-size UDP answer: header + question with TC set, so the client retries over TCP.
    static func truncated(_ resp: Data) -> Data {
        var b = [UInt8](resp)
        guard b.count > 12, let (_, next) = try? DNSMessage.readName(b, 12), next + 4 <= b.count else { return resp }
        b[2] |= 0x02
        b[6] = 0; b[7] = 0; b[8] = 0; b[9] = 0; b[10] = 0; b[11] = 0
        return Data(b[0..<(next + 4)])
    }

    private func acceptLoop(_ fd: Int32) {
        while running {
            guard DNSForwarder.waitReadable(fd, 1) else { continue }
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            queue.async { [weak self] in
                defer { close(c) }
                while let self = self, self.running {
                    guard let lb = DNSForwarder.readExactly(c, 2, 10) else { return }
                    let len = Int(lb[0]) << 8 | Int(lb[1])
                    guard len >= 12, let body = DNSForwarder.readExactly(c, len, 5) else { return }
                    guard let resp = self.forwarder.resolve(Data(body), tcp: true) else { return }
                    var framed = Data([UInt8(resp.count >> 8), UInt8(resp.count & 0xFF)])
                    framed.append(resp)
                    if !DNSForwarder.writeAll(c, framed) { return }
                }
            }
        }
    }
}

@inline(__always)
private func Glibc_listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.listen(fd, backlog)
    #else
    return Darwin.listen(fd, backlog)
    #endif
}

extension DNSMessage {
    /// A/AAAA answer from fixed addresses (DoH bootstrap).
    public static func addressResponse(to query: Data, addresses: [String], ttl: UInt32 = 300) -> Data? {
        guard let q = try? parse(query), let question = q.questions.first else { return nil }
        let b = [UInt8](query)
        guard let (_, next) = try? readName(b, 12), next + 4 <= b.count else { return nil }
        let wantV6 = question.type == DNSRecordType.aaaa.rawValue
        let ips = addresses.compactMap { IPAddress.parse($0) }.filter {
            if case .v6 = $0 { return wantV6 } else { return question.type == DNSRecordType.a.rawValue }
        }
        var answers: [UInt8] = []
        for ip in ips {
            answers += [0xC0, 0x0C, UInt8(question.type >> 8), UInt8(question.type & 0xFF), 0, 1]
            answers += [UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF)]
            answers += [0, UInt8(ip.bytes.count)] + ip.bytes
        }
        let flags: UInt16 = 0x8000 | (q.flags & 0x0100) | 0x0080 | 0x0400
        var out: [UInt8] = [b[0], b[1], UInt8(flags >> 8), UInt8(flags & 0xFF), 0, 1, 0, UInt8(ips.count), 0, 0, 0, 0]
        out += b[12..<(next + 4)]
        out += answers
        return Data(out)
    }
}
