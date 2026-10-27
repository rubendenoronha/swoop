// SPDX-License-Identifier: MIT
//
// The XPC interface between Swoop.app and the Shield system extension. The extension runs
// as root in its own sandbox, so the app hands it config and the compiled index as Data
// rather than file paths. The mach service name comes from the extension's Info.plist
// (NEMachServiceName, "<TeamID>.com.swoopkey.swoop.shield.xpc"); both sides check the
// other's code signature belongs to the same team.
#if canImport(ObjectiveC)
import Foundation

@objc public protocol ShieldXPCProtocol {
    func ping(_ reply: @escaping (String) -> Void)
    func applyConfig(_ json: Data, reply: @escaping (Bool) -> Void)
    func loadIndex(_ data: Data, reply: @escaping (Bool, String?) -> Void)
    func fetchStats(_ reply: @escaping (Data) -> Void)
    func fetchLog(after id: UInt64, reply: @escaping (Data) -> Void)
    func clearLog(_ reply: @escaping () -> Void)
    func resetStats(_ reply: @escaping () -> Void)
}

public enum ShieldXPC {
    public static func interface() -> NSXPCInterface { NSXPCInterface(with: ShieldXPCProtocol.self) }

    /// Code-signing requirement for "signed by this team" (nil when the team isn't known,
    /// e.g. ad-hoc developer builds, which can't load the extension anyway).
    public static func requirement(teamID: String?) -> String? {
        guard let t = teamID, !t.isEmpty, t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(t)\""
    }
}
#endif
