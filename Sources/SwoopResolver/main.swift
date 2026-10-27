// SPDX-License-Identifier: MIT
//
// swoop-resolver: Swoop Shield's fallback DNS filter for Macs where the system extension
// isn't approved. Installed by Swoop as a LaunchDaemon that runs as the installing user;
// launchd binds 127.0.0.1:53 / [::1]:53 (privileged ports) and hands over the sockets.
//
//   swoop-resolver --dir ~/Library/Application\ Support/Swoop/Shield [--listen 127.0.0.1:5353] [--launchd]
//
// Reads <dir>/config.json (ShieldConfig), <dir>/shield.swsh (compiled lists) and
// <dir>/system-dns.txt (the servers macOS used before, one per line); writes <dir>/stats.json
// and, when logging is on, <dir>/querylog.json. Reloads config/lists when they change.
// Never sends anything anywhere except DNS queries to the configured upstream.
import Foundation
import ShieldCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

var args = Array(CommandLine.arguments.dropFirst())
var dir = FileManager.default.currentDirectoryPath
var listens: [String] = []
var useLaunchd = false
var selfTest: String?
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fputs("missing value for \(a)\n", stderr); exit(2) }
        return args.removeFirst()
    }
    switch a {
    case "--dir": dir = value()
    case "--listen": listens.append(value())
    case "--launchd": useLaunchd = true
    case "--self-test": selfTest = value()
    case "-h", "--help":
        print("usage: swoop-resolver --dir DIR [--listen ADDR:PORT]… [--launchd] [--self-test NAME]")
        exit(0)
    default: fputs("unknown option \(a)\n", stderr); exit(2)
    }
}

let base = URL(fileURLWithPath: dir, isDirectory: true)
let configURL = base.appendingPathComponent("config.json")
let indexURL = base.appendingPathComponent("shield.swsh")
let systemDNSURL = base.appendingPathComponent("system-dns.txt")
let statsURL = base.appendingPathComponent("stats.json")
let logURL = base.appendingPathComponent("querylog.json")

func log(_ s: String) { fputs("swoop-resolver: \(s)\n", stderr) }

func mtime(_ u: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date }

func loadConfig() -> ShieldConfig {
    guard let d = try? Data(contentsOf: configURL), let c = ShieldConfig.decode(d) else { return ShieldConfig() }
    return c.pruned(at: Date())
}

func loadIndex() -> ShieldIndex? {
    do { return try ShieldIndex(contentsOf: indexURL) } catch {
        log("lists not loaded (\(error)); only custom rules and the allowlist apply")
        return nil
    }
}

func systemServers() -> [String] {
    let text = (try? String(contentsOf: systemDNSURL, encoding: .utf8)) ?? ""
    let s = text.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "," })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { IPAddress.parse($0) != nil && $0 != "127.0.0.1" && $0 != "::1" }
    // Never loop back to ourselves; fall back to Quad9 when nothing was saved.
    return s.isEmpty ? ["9.9.9.9", "149.112.112.112"] : s
}

var config = loadConfig()
let engine = ShieldEngine(config: config, index: loadIndex())
let forwarder = DNSForwarder(engine: engine, upstreams: DNSForwarder.transports(for: config.upstream, systemServers: systemServers()))

if let name = selfTest {
    let q = DNSMessage.makeQuery(id: 0x5357, name: name, type: DNSRecordType.a.rawValue)
    let d = engine.decide(name: name)
    print("\(name): \(d.action.rawValue) \(d.info?.rule ?? "") \(d.info?.source ?? "")")
    if let r = forwarder.resolve(q), let m = try? DNSMessage.parse(r) {
        print("answer rcode=\(m.rcode) addresses=\(m.addresses) chain=\(m.aliasChain(for: name))")
    }
    exit(0)
}

let server = LocalDNSServer(forwarder: forwarder)

#if os(macOS)
/// launchd socket activation, looked up at runtime (launch_activate_socket, macOS 10.10+).
func launchdSockets(_ name: String) -> [Int32] {
    typealias Fn = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>, UnsafeMutablePointer<Int>) -> Int32
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "launch_activate_socket") else { return [] }   // RTLD_DEFAULT
    let fn = unsafeBitCast(sym, to: Fn.self)
    var fds: UnsafeMutablePointer<Int32>?
    var count = 0
    guard fn(name, &fds, &count) == 0, let p = fds else { return [] }
    defer { free(p) }
    return (0..<count).map { p[$0] }
}
if useLaunchd {
    let udp = launchdSockets("DNSUDP"), tcp = launchdSockets("DNSTCP")
    if udp.isEmpty { log("no launchd sockets (DNSUDP)"); exit(1) }
    server.adopt(udp: udp, tcp: tcp)
}
#else
if useLaunchd { log("--launchd is macOS-only"); exit(2) }
#endif

if listens.isEmpty && !useLaunchd { listens = ["127.0.0.1:53"] }
for l in listens {
    do { let p = try server.listen(l); log("listening on \(l) (port \(p))") } catch { log("\(error)"); exit(1) }
}
server.start()
log("started with \(engine.currentIndex?.domainCount ?? 0) listed domains, upstream \(config.upstream)")

var configTime = mtime(configURL), indexTime = mtime(indexURL), dnsTime = mtime(systemDNSURL)
var lastLogID: UInt64 = 0
let enc = JSONEncoder()
enc.dateEncodingStrategy = .secondsSince1970
var tick = 0
let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
timer.schedule(deadline: .now() + 2, repeating: 2)
timer.setEventHandler {
    tick += 1
    let ct = mtime(configURL), it = mtime(indexURL), dt = mtime(systemDNSURL)
    if ct != configTime || dt != dnsTime || tick % 15 == 0 {   // every 30 s: also expire pauses
        configTime = ct; dnsTime = dt
        config = loadConfig()
        engine.update(config: config)
        forwarder.upstreams = DNSForwarder.transports(for: config.upstream, systemServers: systemServers())
    }
    if it != indexTime {
        indexTime = it
        if let idx = loadIndex() { engine.update(index: idx); log("reloaded lists: \(idx.domainCount) domains") }
    }
    var s = engine.stats.snapshot(top: 25)
    s.mode = "local-resolver"
    s.indexCreatedAt = engine.currentIndex?.createdAt
    s.indexDomains = engine.currentIndex?.domainCount ?? 0
    try? s.encoded().write(to: statsURL, options: .atomic)
    if config.logQueries {
        let entries = engine.stats.entries(after: 0, limit: 2000)
        if entries.last?.id != lastLogID {
            lastLogID = entries.last?.id ?? 0
            let cutoff = Date().addingTimeInterval(-Double(max(1, config.logRetentionHours)) * 3600)
            try? enc.encode(entries.filter { $0.time >= cutoff }).write(to: logURL, options: .atomic)
        }
    } else if FileManager.default.fileExists(atPath: logURL.path) {
        engine.stats.clearLog()
        try? FileManager.default.removeItem(at: logURL)
    }
}
timer.resume()

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }
dispatchMain()
