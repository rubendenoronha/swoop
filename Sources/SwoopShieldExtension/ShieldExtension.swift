// SPDX-License-Identifier: MIT
import Foundation
import ShieldCore

/// Process-wide state shared by both providers and the XPC listener.
final class ShieldExtension: NSObject, NSXPCListenerDelegate, ShieldXPCProtocol {
    static let shared = ShieldExtension()

    let engine: ShieldEngine
    let forwarder: DNSForwarder
    private var listener: NSXPCListener?
    private let storage: URL
    private let queue = DispatchQueue(label: "swoop.shield.ext.persist")

    private override init() {
        // The extension is sandboxed; this resolves inside its own container.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        storage = base.appendingPathComponent("SwoopShield", isDirectory: true)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let config = (try? Data(contentsOf: storage.appendingPathComponent("config.json"))).flatMap(ShieldConfig.decode) ?? ShieldConfig()
        let index = try? ShieldIndex(contentsOf: storage.appendingPathComponent("shield.swsh"))
        engine = ShieldEngine(config: config, index: index)
        forwarder = DNSForwarder(engine: engine, upstreams: [], timeout: 3)
        super.init()
        applyUpstream(config)
    }

    func start() {
        let ne = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        guard let name = ne?["NEMachServiceName"] as? String, !name.isEmpty else {
            NSLog("Swoop Shield: NEMachServiceName missing; the app can't talk to the extension")
            return
        }
        let l = NSXPCListener(machServiceName: name)
        l.delegate = self
        l.resume()
        listener = l
        // Expire pauses even when the app isn't running.
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let c = self.engine.currentConfig
            let p = c.pruned(at: Date())
            if p != c { self.engine.update(config: p) }
        }
        t.resume()
        timer = t
    }
    private var timer: DispatchSourceTimer?

    /// Configured upstream (DoH or fixed servers). `.system` means "forward to the server the
    /// app was asking", decided per flow by the providers.
    var configuredUpstreams: [UpstreamTransport]? {
        let c = engine.currentConfig
        if case .system = c.upstream { return nil }
        return DNSForwarder.transports(for: c.upstream, systemServers: [])
    }

    private func applyUpstream(_ c: ShieldConfig) {
        forwarder.upstreams = DNSForwarder.transports(for: c.upstream, systemServers: [])
    }

    // MARK: XPC

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        let team = Bundle.main.object(forInfoDictionaryKey: "SwoopTeamID") as? String
        if let req = ShieldXPC.requirement(teamID: team) {
            c.setCodeSigningRequirement(req)   // macOS 13+: messages from anyone else are rejected
        }
        c.exportedInterface = ShieldXPC.interface()
        c.exportedObject = self
        c.resume()
        return true
    }

    func ping(_ reply: @escaping (String) -> Void) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        reply("Swoop Shield \(v), \(engine.currentIndex?.domainCount ?? 0) domains")
    }

    func applyConfig(_ json: Data, reply: @escaping (Bool) -> Void) {
        guard let c = ShieldConfig.decode(json) else { return reply(false) }
        engine.update(config: c)
        applyUpstream(c)
        queue.async { try? json.write(to: self.storage.appendingPathComponent("config.json"), options: .atomic) }
        reply(true)
    }

    func loadIndex(_ data: Data, reply: @escaping (Bool, String?) -> Void) {
        do {
            let idx = try ShieldIndex(data: data)   // verifies the checksum
            let url = storage.appendingPathComponent("shield.swsh")
            try data.write(to: url, options: .atomic)
            // Re-open memory-mapped so the copy we were sent can be freed.
            engine.update(index: (try? ShieldIndex(contentsOf: url, verifyChecksum: false)) ?? idx)
            reply(true, nil)
        } catch {
            reply(false, "\(error)")
        }
    }

    func fetchStats(_ reply: @escaping (Data) -> Void) {
        var s = engine.stats.snapshot(top: 25)
        s.mode = "system-extension"
        s.indexCreatedAt = engine.currentIndex?.createdAt
        s.indexDomains = engine.currentIndex?.domainCount ?? 0
        reply(s.encoded())
    }

    func fetchLog(after id: UInt64, reply: @escaping (Data) -> Void) {
        guard engine.currentConfig.logQueries else { return reply(Data("[]".utf8)) }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        reply((try? e.encode(engine.stats.entries(after: id, limit: 1000))) ?? Data("[]".utf8))
    }

    func clearLog(_ reply: @escaping () -> Void) { engine.stats.clearLog(); reply() }
    func resetStats(_ reply: @escaping () -> Void) { engine.stats.resetStats(); reply() }
}
