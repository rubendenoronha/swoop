// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import Security
import ShieldCore

/// Socket-level backstop for the DNS proxy:
///   • drops DNS-over-TLS / DNS-over-QUIC (port 853) and DNS-over-HTTPS to known public
///     resolvers, so browsers and apps can't walk around Shield with their own resolver;
///   • drops connections to blocked hostnames when the app connects by name (catches
///     answers cached before Shield started and apps that resolve elsewhere).
/// Flows are inspected once at connection time; no content is read.
@objc(FilterDataProvider)
final class FilterDataProvider: NEFilterDataProvider {
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        apply(settings) { error in
            if let e = error { NSLog("Swoop Shield filter: \(e)") }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow,
              let remote = socketFlow.remoteEndpoint as? NWHostEndpoint else { return .allow() }
        let proto: FlowProtocol = socketFlow.socketProtocol == IPPROTO_UDP ? .udp : .tcp
        let app = Self.signingIdentifier(auditToken: flow.sourceAppAuditToken)
        let hostname = socketFlow.remoteHostname
        let engine = ShieldExtension.shared.engine
        let verdict = engine.flowVerdict(remoteIP: remote.hostname, remoteHostname: hostname,
                                         port: Int(remote.port) ?? 0, proto: proto, app: app)
        guard case .drop(let reason) = verdict else { return .allow() }
        let decision = ShieldDecision(action: .blocked, info: MatchInfo(source: reason.contains("DNS-over") ? "doh-policy" : "filter", rule: reason), note: "connection")
        engine.stats.record(name: hostname ?? remote.hostname, type: proto == .udp ? "UDP:\(remote.port)" : "TCP:\(remote.port)",
                            app: app, decision: decision, keepLog: engine.currentConfig.logQueries)
        return .drop()
    }

    /// The code-signing identifier ("com.google.Chrome") of the app behind a flow.
    /// (NEFilterFlow.sourceAppIdentifier is iOS-only; macOS gives an audit token.)
    private static let idCache = NSCache<NSData, NSString>()
    static func signingIdentifier(auditToken: Data?) -> String? {
        guard let token = auditToken else { return nil }
        if let hit = idCache.object(forKey: token as NSData) { return hit as String }
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit as String: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let c = code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(c, [], &staticCode) == errSecSuccess, let sc = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let id = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String else { return nil }
        idCache.setObject(id as NSString, forKey: token as NSData)
        return id
    }
}
