// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import ShieldCore

/// System-wide DNS filtering. Every UDP/TCP DNS flow on the Mac arrives here; queries are
/// answered locally when blocked and otherwise forwarded (to the server the app was asking,
/// or Shield's configured upstream) and checked for CNAME-cloaked trackers.
@objc(DNSProxyProvider)
final class DNSProxyProvider: NEDNSProxyProvider {
    private let work = DispatchQueue(label: "swoop.shield.dns", qos: .userInitiated, attributes: .concurrent)

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Never filter DNS next to Pax (the app doesn't enable the proxy then; this is the backstop).
        if ShieldExtension.shared.engine.currentConfig.paxCompatible {
            NSLog("Swoop Shield: Pax is filtering DNS on this Mac; the DNS proxy stays off")
            completionHandler(NSError(domain: "com.swoopkey.swoop.shield", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Pax is filtering DNS on this Mac"]))
            return
        }
        NSLog("Swoop Shield DNS proxy started")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("Swoop Shield DNS proxy stopped (\(reason.rawValue))")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let app = flow.metaData.sourceAppSigningIdentifier
        if let udp = flow as? NEAppProxyUDPFlow {
            UDPRelay(flow: udp, app: app, queue: work).start()
            return true
        }
        if let tcp = flow as? NEAppProxyTCPFlow {
            TCPRelay(flow: tcp, app: app, queue: work).start()
            return true
        }
        return false
    }
}

private func upstreams(for endpoint: NWEndpoint?) -> [UpstreamTransport] {
    if let configured = ShieldExtension.shared.configuredUpstreams { return configured }
    guard let host = endpoint as? NWHostEndpoint, let port = UInt16(host.port),
          let addr = SocketAddress(host: host.hostname, port: port) else { return [] }
    return [.udp(addr)]
}

private final class UDPRelay {
    let flow: NEAppProxyUDPFlow
    let app: String
    let queue: DispatchQueue

    init(flow: NEAppProxyUDPFlow, app: String, queue: DispatchQueue) {
        self.flow = flow
        self.app = app
        self.queue = queue
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [self] error in
            if let e = error { NSLog("Swoop Shield: UDP flow open failed: \(e)"); return }
            read()
        }
    }

    private func read() {
        flow.readDatagrams { [self] datagrams, endpoints, error in
            guard error == nil, let datagrams = datagrams, let endpoints = endpoints, !datagrams.isEmpty else {
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
                return
            }
            for (packet, endpoint) in zip(datagrams, endpoints) {
                queue.async { [self] in
                    let via = upstreams(for: endpoint)
                    guard let answer = ShieldExtension.shared.forwarder.resolve(packet, app: app, via: via) else { return }
                    flow.writeDatagrams([answer], sentBy: [endpoint]) { _ in }
                }
            }
            read()
        }
    }
}

private final class TCPRelay {
    let flow: NEAppProxyTCPFlow
    let app: String
    let queue: DispatchQueue
    private var buffer = Data()

    init(flow: NEAppProxyTCPFlow, app: String, queue: DispatchQueue) {
        self.flow = flow
        self.app = app
        self.queue = queue
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [self] error in
            if error != nil { return }
            read()
        }
    }

    private func read() {
        flow.readData { [self] data, error in
            guard error == nil, let d = data, !d.isEmpty else {
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
                return
            }
            buffer.append(d)
            // DNS over TCP: 2-byte big-endian length, then the message.
            while buffer.count >= 2 {
                let len = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
                guard buffer.count >= 2 + len else { break }
                let msg = Data(buffer[(buffer.startIndex + 2)..<(buffer.startIndex + 2 + len)])
                buffer.removeFirst(2 + len)
                let via = upstreams(for: flow.remoteEndpoint)
                queue.async { [self] in
                    guard let answer = ShieldExtension.shared.forwarder.resolve(msg, app: app, tcp: true, via: via) else { return }
                    var framed = Data([UInt8(answer.count >> 8), UInt8(answer.count & 0xFF)])
                    framed.append(answer)
                    flow.write(framed) { _ in }
                }
            }
            read()
        }
    }
}
