// SPDX-License-Identifier: MIT
//
// Swoop Shield, app side: owns the user's Shield settings, turns the chosen protection
// layer on and off (system extension, local resolver, encrypted-DNS profile), pushes
// config and compiled lists to it, and collects stats for the Shield tab and menu bar.
// Everything stays on this Mac.
import AppKit
import Foundation
import NetworkExtension
import SafariServices
import Security
import ShieldCore
import SystemExtensions

enum ShieldMode: String, CaseIterable, Identifiable {
    case systemExtension, localResolver, encryptedProfile, browserOnly, worksWithPax
    var id: String { rawValue }

    /// The modes that filter DNS for the whole Mac. None of them run next to Pax.
    var isDNSLevel: Bool { self == .systemExtension || self == .localResolver || self == .encryptedProfile }

    var layer: ShieldLayer {
        switch self {
        case .systemExtension: return .dnsProxy
        case .localResolver: return .localResolver
        case .encryptedProfile: return .encryptedDNSProfile
        case .browserOnly: return .browserExtension
        case .worksWithPax: return .contentFilterDropOnly
        }
    }

    var title: String {
        switch self {
        case .systemExtension: return "System extension (recommended)"
        case .localResolver: return "Local resolver"
        case .encryptedProfile: return "Encrypted DNS profile"
        case .browserOnly: return "Browsers only"
        case .worksWithPax: return "Works with Pax"
        }
    }

    var detail: String {
        switch self {
        case .systemExtension:
            return "Filters DNS for every app and browser on this Mac, uncloaks CNAME trackers and stops apps bypassing it with their own encrypted DNS. Needs one approval in System Settings."
        case .localResolver:
            return "If you'd rather not approve a system extension: a small filtering DNS server on 127.0.0.1, set as your Mac's DNS. Same lists, stats and allowlist. Asks for your admin password once; turning Shield off puts your DNS back."
        case .encryptedProfile:
            return "Switches macOS to a public ad-blocking DNS server with a configuration profile. Not on-device: the provider's lists apply, not Swoop's, and there are no stats."
        case .browserOnly:
            return "No system-wide filtering; only the Safari and Chrome/Firefox extensions block ads."
        case .worksWithPax:
            return "Pax already filters DNS for this whole Mac, so Shield stays out of its way: it blocks ads in Safari and your other browsers, never touches DNS, /etc/hosts or the firewall, and never blocks Pax's servers. For system-wide ad blocking, turn on Pax's Ads switch."
        }
    }
}

enum ShieldStatus: Equatable {
    case off
    case starting(String)
    case needsApproval(String)
    case active(String)
    case paused(until: Date)
    case problem(String)

    var isProtecting: Bool { if case .active = self { return true }; return false }
}

final class ShieldController: NSObject, ObservableObject {
    static let shared = ShieldController()
    static let extensionID = "com.swoopkey.swoop.shield"
    static let resolverLabel = "com.swoopkey.swoop.resolver"
    static let safariBlockerCount = SafariConverter.defaultChunkCount

    @Published private(set) var config: ShieldConfig
    @Published var mode: ShieldMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "shieldMode") } }
    @Published private(set) var status: ShieldStatus = .off
    @Published private(set) var stats: ShieldStats?
    @Published private(set) var log: [QueryLogEntry] = []
    @Published var menuBarCounter: Bool {
        didSet { UserDefaults.standard.set(menuBarCounter, forKey: "shieldMenuBarCounter"); MenuBarMonitor.shared.refreshVisibility() }
    }
    @Published var profileProvider: String { didSet { UserDefaults.standard.set(profileProvider, forKey: "shieldProfileProvider") } }
    /// Pax (accountability blocker) found on this Mac: Shield runs in "Works with Pax" mode.
    @Published private(set) var pax: PaxPresence = .absent
    var paxPresent: Bool { pax.detected }
    private var paxCheckCounter = 0

    let lists = ShieldListManager()
    private var xpc: NSXPCConnection?
    private var pollTimer: Timer?
    private var lastLogID: UInt64 = 0
    var uiVisible = false

    /// ~/Library/Application Support/Swoop/Shield
    static let dir: URL = {
        let u = AppPaths.support.appendingPathComponent("Shield", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// App Group shared with the Safari extensions ("<TeamID>.com.swoopkey.swoop.shield").
    static var appGroup: String { Bundle.main.object(forInfoDictionaryKey: "SwoopAppGroup") as? String ?? "" }
    static var groupDir: URL? {
        guard !appGroup.isEmpty, let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let d = u.appendingPathComponent("Shield", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private override init() {
        let d = UserDefaults.standard
        d.register(defaults: ["shieldMenuBarCounter": true, "shieldProfileProvider": "adguard"])
        let configURL = ShieldController.dir.appendingPathComponent("config.json")
        var c = (try? Data(contentsOf: configURL)).flatMap(ShieldConfig.decode) ?? ShieldConfig()
        if d.object(forKey: "shieldMode") == nil { c.enabled = false }   // first run: off until the user turns it on
        config = c.pruned(at: Date())
        mode = ShieldMode(rawValue: d.string(forKey: "shieldMode") ?? "") ?? .systemExtension
        menuBarCounter = d.bool(forKey: "shieldMenuBarCounter")
        profileProvider = d.string(forKey: "shieldProfileProvider") ?? "adguard"
        super.init()
    }

    // MARK: capabilities

    /// The system extension is in the bundle and the app carries the Network Extension
    /// entitlement (only true for Developer ID builds with the provisioning profile).
    var systemExtensionAvailable: Bool {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(ShieldController.extensionID).systemextension")
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, "com.apple.developer.networking.networkextension" as CFString, nil) else { return false }
        return (v as? [String])?.contains("dns-proxy-systemextension") ?? false
    }

    var resolverInstalled: Bool { FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(ShieldController.resolverLabel).plist") }

    // MARK: lifecycle

    func start() {
        // Pax first: nothing DNS-level may start before we know it isn't there.
        let (_, presence) = PaxDetector.scan()
        pax = presence
        if presence.detected { enterPaxMode(initial: true) }
        lists.onCompiled = { [weak self] index in self?.distribute(index: index) }
        lists.start(enabledIDs: config.enabledLists)
        if config.enabled { activate(mode) }
        writeBrowserState()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        poll()
    }

    func setEnabled(_ on: Bool) {
        update { $0.enabled = on; if on { $0.pausedUntil = nil } }
        if on { activate(mode) } else { deactivate(mode) }
    }

    func switchMode(to new: ShieldMode) {
        guard new != mode else { return }
        if paxPresent && !PaxCompatibility.permits(new.layer, paxPresent: true) {
            Actions.info("Pax is filtering this Mac", "Pax already filters DNS here, and a second DNS filter would clash with it. Shield keeps blocking ads in your browsers; for system-wide ad blocking, turn on Pax's Ads switch.")
            return
        }
        if new == .worksWithPax && !paxPresent { return }
        if config.enabled { deactivate(mode) }
        mode = new
        if config.enabled { activate(new) }
    }

    private func activate(_ m: ShieldMode) {
        // Hard rule: no DNS-level layer next to Pax, whatever led here.
        if paxPresent && !PaxCompatibility.permits(m.layer, paxPresent: true) {
            if mode != .worksWithPax { enterPaxMode(initial: false) }
            return
        }
        switch m {
        case .systemExtension:
            guard systemExtensionAvailable else {
                setStatus(.problem("This copy of Swoop wasn't built with the Network Extension entitlement (Developer ID + provisioning profile). Use Local resolver, or install the signed release."))
                return
            }
            setStatus(.starting("Installing the Shield system extension…"))
            let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: ShieldController.extensionID, queue: .main)
            req.delegate = self
            OSSystemExtensionManager.shared.submitRequest(req)
        case .localResolver:
            installLocalResolver()
        case .encryptedProfile:
            installProfile()
        case .browserOnly:
            setStatus(.active("Browser extensions only"))
        case .worksWithPax:
            if config.paxContentFilter && systemExtensionAvailable {
                setStatus(.starting("Starting the content filter…"))
                let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: ShieldController.extensionID, queue: .main)
                req.delegate = self
                OSSystemExtensionManager.shared.submitRequest(req)
            } else {
                if systemExtensionAvailable { configureManagers(enabled: false) }
                setStatus(.active("Works with Pax · browsers"))
            }
        }
        writeBrowserState()
    }

    // MARK: Works with Pax

    /// Pax found: stop every DNS-level layer without touching network DNS settings, /etc/hosts
    /// or pf (Pax owns those), and switch to browser-level blocking.
    private func enterPaxMode(initial: Bool) {
        if mode != .worksWithPax {
            UserDefaults.standard.set(mode.rawValue, forKey: "shieldModeBeforePax")
        }
        let previous = mode
        if previous == .systemExtension, systemExtensionAvailable { configureManagers(enabled: false) }
        if resolverInstalled { removeLocalResolverKeepingDNS() }
        mode = .worksWithPax
        if !config.paxCompatible {
            update { $0.paxCompatible = true }
        }
        if previous == .encryptedProfile {
            Actions.info("Remove the Swoop Shield DNS profile", "Pax is filtering this Mac, and Shield's DNS profile would override it. Open System Settings › Privacy & Security › Profiles (macOS 13–14: System Settings › Profiles), select \"Swoop Shield\" and click Remove.")
        }
        if config.enabled && !initial { activate(.worksWithPax) }
        if !initial { Notifier.show("Shield now works with Pax", body: "Pax filters DNS on this Mac; Shield blocks ads in your browsers.") }
    }

    /// Pax removed: go back to the mode the user had before.
    private func leavePaxMode() {
        guard mode == .worksWithPax else { return }
        if systemExtensionAvailable { configureManagers(enabled: false) }
        update { $0.paxCompatible = false }
        let before = ShieldMode(rawValue: UserDefaults.standard.string(forKey: "shieldModeBeforePax") ?? "") ?? .browserOnly
        mode = before == .worksWithPax ? .browserOnly : before
        if config.enabled { activate(mode) }
    }

    /// Re-checks for Pax (every minute, and when the Shield tab opens).
    func recheckPax() {
        DispatchQueue.global(qos: .utility).async {
            let (_, p) = PaxDetector.scan()
            DispatchQueue.main.async {
                let was = self.pax.detected
                self.pax = p
                if p.detected && (!was || self.mode != .worksWithPax || !self.config.paxCompatible) { self.enterPaxMode(initial: false) }
                else if !p.detected && was { self.leavePaxMode() }
            }
        }
    }

    func setPaxContentFilter(_ on: Bool) {
        update { $0.paxContentFilter = on }
        if mode == .worksWithPax && config.enabled { activate(.worksWithPax) }
    }

    private func deactivate(_ m: ShieldMode) {
        switch m {
        case .systemExtension:
            configureManagers(enabled: false)
        case .localResolver:
            uninstallLocalResolver()
        case .encryptedProfile:
            Actions.info("Remove the Shield profile", "Open System Settings › Privacy & Security › Profiles (macOS 13–14: System Settings › Profiles), select \"Swoop Shield\" and click Remove.")
            openProfilesSettings()
        case .browserOnly:
            break
        }
        setStatus(.off)
        writeBrowserState()
    }

    /// Fully removes the system extension (Shield › Advanced).
    func uninstallSystemExtension() {
        configureManagers(enabled: false)
        let req = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: ShieldController.extensionID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    private func setStatus(_ s: ShieldStatus) {
        DispatchQueue.main.async { self.status = s; MenuBarMonitor.shared.refreshVisibility() }
    }

    // MARK: settings changes

    /// The one way settings change: mutate, save, push to whatever is filtering.
    func update(_ change: (inout ShieldConfig) -> Void) {
        var c = config
        change(&c)
        c = c.pruned(at: Date())
        let listsChanged = c.enabledLists != config.enabledLists
        config = c
        try? c.encoded().write(to: ShieldController.dir.appendingPathComponent("config.json"), options: .atomic)
        pushConfig()
        writeBrowserState()
        if listsChanged { lists.setEnabled(c.enabledLists) }
    }

    func pause(minutes: Int) {
        update { $0.pausedUntil = Date().addingTimeInterval(Double(minutes) * 60) }
        Notifier.show("Ad blocking paused for \(minutes) min")
    }

    func resume() {
        update { $0.pausedUntil = nil }
        Notifier.show("Ad blocking resumed")
    }

    func allow(site raw: String) {
        guard let host = DomainName.host(fromURLOrHost: raw) else { return }
        let site = DomainName.registrableDomain(host)
        update { c in if !c.allowlist.contains(site) { c.allowlist.append(site) } }
        Notifier.show("Allowed \(site)", body: "Shield won't block it any more. Remove it in Shield › Allowlist.")
    }

    func removeAllowed(_ site: String) { update { $0.allowlist.removeAll { $0 == site } } }

    func block(site raw: String) {
        guard let host = DomainName.host(fromURLOrHost: raw) else { return }
        update { c in
            let rule = "||\(host)^"
            if !c.customRules.components(separatedBy: .newlines).contains(rule) {
                c.customRules += (c.customRules.isEmpty || c.customRules.hasSuffix("\n") ? "" : "\n") + rule + "\n"
            }
            c.allowlist.removeAll { DomainName.isSubdomain(host, of: $0) }
        }
        Notifier.show("Blocking \(host)")
    }

    func pause(site raw: String, minutes: Int?) {
        guard let host = DomainName.host(fromURLOrHost: raw) else { return }
        let site = DomainName.registrableDomain(host)
        update { c in
            c.sitePauses.removeAll { $0.domain == site }
            c.sitePauses.append(SitePause(domain: site, until: minutes.map { Date().addingTimeInterval(Double($0) * 60) }))
        }
    }

    func pause(app bundleID: String, name: String, minutes: Int?) {
        update { c in
            c.appPauses.removeAll { $0.id == bundleID }
            c.appPauses.append(AppPause(id: bundleID, name: name, until: minutes.map { Date().addingTimeInterval(Double($0) * 60) }))
        }
    }

    // MARK: pushing to the filter

    private func pushConfig() {
        let data = config.encoded()
        switch mode {
        case .systemExtension, .worksWithPax:
            proxy()?.applyConfig(data) { _ in }
        case .localResolver:
            break   // the resolver watches config.json, written in update()
        default:
            break
        }
    }

    /// New compiled lists from ShieldListManager.
    private func distribute(index: Data) {
        if mode == .systemExtension || (mode == .worksWithPax && config.paxContentFilter), config.enabled {
            proxy()?.loadIndex(index) { ok, err in if !ok { NSLog("Shield: extension refused the index: \(err ?? "?")") } }
        }
        // config.json and shield.swsh live in ShieldController.dir, which the local resolver reads.
        reloadSafari()
    }

    func reloadSafari() {
        for n in 1...ShieldController.safariBlockerCount {
            SFContentBlockerManager.reloadContentBlocker(withIdentifier: "com.swoopkey.swoop.safari.blocker\(n)") { err in
                if let e = err { NSLog("Shield: Safari blocker \(n): \(e.localizedDescription)") }
            }
        }
    }

    /// Shield on/off and paused sites for the browser extensions.
    private func writeBrowserState() {
        let paused = config.sitePauses.map { $0.domain } + config.allowlist
        let obj: [String: Any] = ["enabled": config.enabled && !config.isPaused(at: Date()), "pausedSites": paused,
                                  "pausedUntil": config.pausedUntil?.timeIntervalSince1970 ?? 0]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        if let g = ShieldController.groupDir { try? data.write(to: g.appendingPathComponent("browser-state.json"), options: .atomic) }
        try? data.write(to: ShieldController.dir.appendingPathComponent("browser-state.json"), options: .atomic)
    }

    // MARK: system extension

    private func configureManagers(enabled: Bool) {
        let dns = NEDNSProxyManager.shared()
        dns.loadFromPreferences { [weak self] _ in
            let proto = NEDNSProxyProviderProtocol()
            proto.providerBundleIdentifier = ShieldController.extensionID
            proto.serverAddress = "Swoop Shield"
            dns.providerProtocol = proto
            dns.localizedDescription = "Swoop Shield"
            // Never a DNS proxy next to Pax (it treats one as tampering).
            dns.isEnabled = enabled && self?.mode == .systemExtension && self?.paxPresent == false
            dns.saveToPreferences { err in
                if let e = err { self?.setStatus(.problem("DNS proxy: \(e.localizedDescription)")); return }
                if enabled && dns.isEnabled { self?.afterExtensionReady() }
            }
        }
        let filter = NEFilterManager.shared()
        filter.loadFromPreferences { [weak self] _ in
            let fc = NEFilterProviderConfiguration()
            fc.filterSockets = true
            fc.filterPackets = false
            fc.filterDataProviderBundleIdentifier = ShieldController.extensionID
            fc.organization = "Swoop"
            filter.providerConfiguration = fc
            filter.localizedDescription = "Swoop Shield"
            // The content filter only blocks encrypted-DNS bypass and blocked hostnames.
            // Next to Pax only the drop-only filter may run, and only if the user turned it on.
            let paxFilter = self?.mode == .worksWithPax && self?.config.paxContentFilter == true
            let normalFilter = self?.mode == .systemExtension && self?.paxPresent == false && self?.config.encryptedDNS == .blockBypass
            filter.isEnabled = enabled && (paxFilter || normalFilter)
            filter.saveToPreferences { err in
                if let e = err { NSLog("Shield filter: \(e.localizedDescription)"); return }
                if enabled && paxFilter { self?.afterExtensionReady() }
            }
        }
    }

    private func afterExtensionReady() {
        setStatus(.active(mode == .worksWithPax ? "Works with Pax · browsers + content filter" : "System-wide (system extension)"))
        proxy()?.applyConfig(config.encoded()) { _ in }
        if let idx = try? Data(contentsOf: ShieldController.dir.appendingPathComponent("shield.swsh")) {
            proxy()?.loadIndex(idx) { _, _ in }
        }
    }

    private func proxy() -> ShieldXPCProtocol? {
        if xpc == nil {
            let name = Bundle.main.object(forInfoDictionaryKey: "SwoopShieldMachService") as? String ?? ""
            guard !name.isEmpty else { return nil }
            let c = NSXPCConnection(machServiceName: name, options: [])
            c.remoteObjectInterface = ShieldXPC.interface()
            if let req = ShieldXPC.requirement(teamID: Bundle.main.object(forInfoDictionaryKey: "SwoopTeamID") as? String) {
                c.setCodeSigningRequirement(req)
            }
            c.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.xpc = nil } }
            c.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.xpc = nil } }
            c.resume()
            xpc = c
        }
        return xpc?.remoteObjectProxyWithErrorHandler { _ in } as? ShieldXPCProtocol
    }

    // MARK: local resolver (fallback)

    private func installLocalResolver() {
        guard !paxPresent else { return }   // port 53 and the DNS settings belong to Pax
        guard let bin = Bundle.main.url(forAuxiliaryExecutable: "swoop-resolver") else {
            setStatus(.problem("swoop-resolver is missing from the app bundle."))
            return
        }
        try? config.encoded().write(to: ShieldController.dir.appendingPathComponent("config.json"), options: .atomic)
        let dir = ShieldController.dir.path
        let user = NSUserName()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(ShieldController.resolverLabel)</string>
          <key>ProgramArguments</key><array>
            <string>/Library/Application Support/Swoop/swoop-resolver</string><string>--dir</string><string>\(xmlEscape(dir))</string><string>--launchd</string>
          </array>
          <key>UserName</key><string>\(xmlEscape(user))</string>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Interactive</string>
          <key>Sockets</key><dict>
            <key>DNSUDP</key><array>
              <dict><key>SockNodeName</key><string>127.0.0.1</string><key>SockServiceName</key><string>53</string><key>SockType</key><string>dgram</string></dict>
              <dict><key>SockNodeName</key><string>::1</string><key>SockServiceName</key><string>53</string><key>SockType</key><string>dgram</string></dict>
            </array>
            <key>DNSTCP</key><array>
              <dict><key>SockNodeName</key><string>127.0.0.1</string><key>SockServiceName</key><string>53</string><key>SockType</key><string>stream</string></dict>
              <dict><key>SockNodeName</key><string>::1</string><key>SockServiceName</key><string>53</string><key>SockType</key><string>stream</string></dict>
            </array>
          </dict>
          <key>StandardErrorPath</key><string>/var/log/swoop-resolver.log</string>
        </dict></plist>
        """
        let tmpPlist = FileManager.default.temporaryDirectory.appendingPathComponent("\(ShieldController.resolverLabel).plist")
        try? plist.write(to: tmpPlist, atomically: true, encoding: .utf8)
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        set -e
        mkdir -p '/Library/Application Support/Swoop'
        cp \(q(bin.path)) '/Library/Application Support/Swoop/swoop-resolver'
        chown root:wheel '/Library/Application Support/Swoop/swoop-resolver'; chmod 755 '/Library/Application Support/Swoop/swoop-resolver'
        D=\(q(dir))
        scutil --dns | awk '/nameserver\\[[0-9]+\\]/{print $3}' | grep -v -e '^127\\.' -e '^::1$' | sort -u > "$D/system-dns.txt" || true
        chown \(q(user)) "$D/system-dns.txt"
        : > "$D/previous-dns.tsv"
        networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do
          cur=$(networksetup -getdnsservers "$svc" | tr '\\n' ' ')
          printf '%s\\t%s\\n' "$svc" "$cur" >> "$D/previous-dns.tsv"
        done
        chown \(q(user)) "$D/previous-dns.tsv"
        cp \(q(tmpPlist.path)) /Library/LaunchDaemons/\(ShieldController.resolverLabel).plist
        chown root:wheel /Library/LaunchDaemons/\(ShieldController.resolverLabel).plist; chmod 644 /Library/LaunchDaemons/\(ShieldController.resolverLabel).plist
        launchctl bootout system/\(ShieldController.resolverLabel) 2>/dev/null || true
        launchctl bootstrap system /Library/LaunchDaemons/\(ShieldController.resolverLabel).plist
        sleep 1
        networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do
          networksetup -setdnsservers "$svc" 127.0.0.1 ::1
        done
        dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
        """
        setStatus(.starting("Installing the local resolver…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, out) = Shell.runAsAdmin(script, prompt: "Swoop Shield wants to set up its local ad-blocking DNS resolver.")
            self.setStatus(ok ? .active("System-wide (local resolver)") : .problem(out.isEmpty ? "Cancelled." : out))
        }
    }

    private func uninstallLocalResolver() {
        guard resolverInstalled else { return }
        if paxPresent { removeLocalResolverKeepingDNS(); return }
        let dir = ShieldController.dir.path
        let script = """
        D='\(dir.replacingOccurrences(of: "'", with: "'\\''"))'
        if [ -f "$D/previous-dns.tsv" ]; then
          while IFS="$(printf '\\t')" read -r svc cur; do
            case "$cur" in *"aren't any"*|"") networksetup -setdnsservers "$svc" Empty ;; *) networksetup -setdnsservers "$svc" $cur ;; esac
          done < "$D/previous-dns.tsv"
        else
          networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do networksetup -setdnsservers "$svc" Empty; done
        fi
        launchctl bootout system/\(ShieldController.resolverLabel) 2>/dev/null || true
        rm -f /Library/LaunchDaemons/\(ShieldController.resolverLabel).plist '/Library/Application Support/Swoop/swoop-resolver'
        dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, out) = Shell.runAsAdmin(script, prompt: "Swoop Shield wants to remove its local resolver and restore your DNS settings.")
            if !ok { DispatchQueue.main.async { Actions.info("Couldn't remove the local resolver", out.isEmpty ? "Cancelled." : out) } }
        }
    }

    /// Stops and removes swoop-resolver without touching any network DNS settings (used when
    /// Pax is present: the DNS settings are Pax's, and changing them would look like tampering).
    private func removeLocalResolverKeepingDNS() {
        let script = """
        launchctl bootout system/\(ShieldController.resolverLabel) 2>/dev/null || true
        rm -f /Library/LaunchDaemons/\(ShieldController.resolverLabel).plist '/Library/Application Support/Swoop/swoop-resolver'
        """
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Shell.runAsAdmin(script, prompt: "Pax is filtering this Mac. Swoop wants to remove its own local resolver so the two don't clash (your DNS settings stay as they are).")
        }
    }

    // MARK: encrypted DNS profile (fallback)

    private func installProfile() {
        guard !paxPresent else { return }
        guard let p = DNSProfileBuilder.providers.first(where: { $0.id == profileProvider }) ?? DNSProfileBuilder.providers.first else { return }
        let xml = DNSProfileBuilder.profile(name: p.name, url: p.url, addresses: p.addresses)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Swoop Shield DNS.mobileconfig")
        do { try xml.write(to: url, atomically: true, encoding: .utf8) } catch { setStatus(.problem(error.localizedDescription)); return }
        NSWorkspace.shared.open(url)
        setStatus(.needsApproval("Open System Settings › Privacy & Security › Profiles, double-click \"Swoop Shield\" and click Install."))
        openProfilesSettings()
    }

    private func openProfilesSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    // MARK: stats

    private func poll() {
        paxCheckCounter += 1
        if paxCheckCounter >= 30 { paxCheckCounter = 0; recheckPax() }   // every ~60 s
        // Expire pauses and keep the menu bar honest even when nobody looks at the tab.
        if let until = config.pausedUntil {
            if until <= Date() { update { $0.pausedUntil = nil } } else if config.enabled && status != .paused(until: until) { status = .paused(until: until) }
        } else if case .paused = status { activateStatusAfterPause() }
        switch mode {
        case .systemExtension, .worksWithPax:
            guard config.enabled, systemExtensionAvailable, mode == .systemExtension || config.paxContentFilter else { return }
            proxy()?.fetchStats { [weak self] data in
                guard let s = ShieldStats.decode(data) else { return }
                DispatchQueue.main.async { self?.stats = s; MenuBarMonitor.shared.refreshVisibility() }
            }
            if uiVisible && config.logQueries {
                proxy()?.fetchLog(after: lastLogID) { [weak self] data in
                    let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
                    guard let entries = try? d.decode([QueryLogEntry].self, from: data), !entries.isEmpty else { return }
                    DispatchQueue.main.async { self?.appendLog(entries) }
                }
            }
        case .localResolver:
            guard config.enabled else { return }
            if let d = try? Data(contentsOf: ShieldController.dir.appendingPathComponent("stats.json")), let s = ShieldStats.decode(d) {
                stats = s
                MenuBarMonitor.shared.refreshVisibility()
            }
            if uiVisible && config.logQueries, let d = try? Data(contentsOf: ShieldController.dir.appendingPathComponent("querylog.json")) {
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
                if let entries = try? dec.decode([QueryLogEntry].self, from: d) { appendLog(entries.filter { $0.id > lastLogID }) }
            }
        default:
            break
        }
    }

    private func activateStatusAfterPause() {
        switch mode {
        case .systemExtension: status = .active("System-wide (system extension)")
        case .localResolver: status = .active("System-wide (local resolver)")
        case .browserOnly: status = .active("Browser extensions only")
        case .encryptedProfile: status = .active("Encrypted DNS profile")
        case .worksWithPax: status = .active(config.paxContentFilter && systemExtensionAvailable ? "Works with Pax · browsers + content filter" : "Works with Pax · browsers")
        }
    }

    private func appendLog(_ entries: [QueryLogEntry]) {
        guard !entries.isEmpty else { return }
        lastLogID = max(lastLogID, entries.map { $0.id }.max() ?? 0)
        log.append(contentsOf: entries)
        let cutoff = Date().addingTimeInterval(-Double(max(1, config.logRetentionHours)) * 3600)
        log.removeAll { $0.time < cutoff }
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    func clearLog() {
        log.removeAll()
        proxy()?.clearLog {}
        try? FileManager.default.removeItem(at: ShieldController.dir.appendingPathComponent("querylog.json"))
    }

    func resetStats() {
        proxy()?.resetStats {}
        stats = nil
    }

    var menuBarText: String? {
        guard menuBarCounter, config.enabled, let s = stats else { return nil }
        if config.isPaused(at: Date()) { return "⏸" }
        return ShieldStats.compact(s.blockedToday)
    }

    /// Text for the launcher's "Shield Stats" command.
    func statsSummary() -> String {
        var lines: [String] = []
        let modeText: String
        switch status {
        case .active(let m): modeText = "On · \(m)"
        case .paused(let u): modeText = "Paused until \(DateFormatter.localizedString(from: u, dateStyle: .none, timeStyle: .short))"
        case .off: modeText = "Off"
        case .starting(let s), .needsApproval(let s), .problem(let s): modeText = s
        }
        lines.append("Swoop Shield: \(modeText)")
        if let s = stats {
            lines.append("")
            lines.append("Today: \(s.blockedToday) of \(s.queriesToday) lookups blocked (\(String(format: "%.1f", s.blockedPercentToday))%)")
            lines.append("Since \(DateFormatter.localizedString(from: s.since, dateStyle: .medium, timeStyle: .short)): \(s.blockedTotal) blocked, \(s.cnameBlockedTotal) cloaked trackers, \(s.bypassBlockedTotal) DNS bypass attempts")
            if !s.topBlocked.isEmpty {
                lines.append("")
                lines.append("Top blocked:")
                for t in s.topBlocked.prefix(10) { lines.append("  \(t.count)×  \(t.name)") }
            }
            if let c = s.indexCreatedAt { lines.append(""); lines.append("Lists: \(s.indexDomains) domains, compiled \(RelativeDateTimeFormatter().localizedString(for: c, relativeTo: Date()))") }
        } else {
            lines.append("No stats yet.")
        }
        return lines.joined(separator: "\n")
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension ShieldController: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        setStatus(.needsApproval("Approve \"Swoop\" in System Settings › General › Login Items & Extensions › Network Extensions (macOS 13–14: Privacy & Security › Allow). Swoop must be in your Applications folder."))
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if config.enabled && (mode == .systemExtension || (mode == .worksWithPax && config.paxContentFilter)) {
            configureManagers(enabled: true)
            if result == .willCompleteAfterReboot { setStatus(.needsApproval("Restart your Mac to finish installing Shield.")) }
        } else {
            setStatus(.off)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let e = error as NSError
        var msg = e.localizedDescription
        if e.domain == OSSystemExtensionErrorDomain, e.code == OSSystemExtensionError.Code.unsupportedParentBundleLocation.rawValue {
            msg = "Move Swoop to your Applications folder, open it from there and try again."
        }
        setStatus(.problem(msg))
    }
}
