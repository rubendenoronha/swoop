// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import SwoopCore

// MARK: - Space Lens

final class SpaceLensModel: ObservableObject {
    @Published var stack: [DiskNode] = []
    @Published var scanning = false
    @Published var count = 0
    @Published var hovered: String?
    private var cancel = CancelToken()

    var current: DiskNode? { stack.last }

    func scan(_ url: URL, push: Bool = false) {
        cancel.cancel(); cancel = CancelToken()
        let c = cancel
        scanning = true; count = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let root = SpaceScanner.scan(url, depth: 3, cancel: c) { n in self.count = n }
            DispatchQueue.main.async {
                guard !c.cancelled else { return }
                if push, !self.stack.isEmpty { self.stack.append(root) } else { self.stack = [root] }
                self.scanning = false
            }
        }
    }

    func open(_ n: DiskNode) {
        guard n.isDirectory else { return }
        if n.children.isEmpty { scan(URL(fileURLWithPath: n.path), push: true) } else { stack.append(n) }
    }

    func stop() { cancel.cancel(); scanning = false }
}

struct SpaceLensView: View {
    @StateObject private var m = SpaceLensModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .spaceLens, subtitle: "An interactive map of your disk. Bigger tiles are bigger folders; click a folder to go inside.") {
                HStack {
                    Button("Home Folder") { m.scan(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Whole Disk") { m.scan(URL(fileURLWithPath: "/")) }
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { m.scan(u) }
                    }
                }
            }
            if m.scanning {
                VStack { ScanningView(text: "Measured \(m.count) items…"); Button("Stop") { m.stop() }.padding(.bottom, 30) }
            } else if let node = m.current {
                breadcrumb
                HStack(spacing: 0) {
                    TreemapView(node: node, hovered: $m.hovered) { m.open($0) }
                        .padding(12)
                    Divider()
                    SpaceList(node: node, open: { m.open($0) }, rescan: {
                        if let r = m.stack.first { m.scan(URL(fileURLWithPath: r.path)) }
                    }).frame(width: 320)
                }
            } else {
                StartView(text: "Map your home folder or the whole disk. Folders you can't read without Full Disk Access show as smaller than they are.",
                          button: "Map Home Folder", feature: .protectedFolders) { m.scan(FileManager.default.homeDirectoryForCurrentUser) }
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(m.stack.enumerated()), id: \.offset) { i, n in
                if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary) }
                Button(n.name) { m.stack = Array(m.stack.prefix(i + 1)) }.buttonStyle(.link)
            }
            Spacer()
            if let c = m.current { Text(Bytes.format(c.size)).foregroundColor(.secondary) }
            if let h = m.hovered { Text(h).font(.caption).foregroundColor(.secondary).lineLimit(1) }
        }.padding(.horizontal, 24)
    }
}

struct TreemapView: View {
    let node: DiskNode
    @Binding var hovered: String?
    let open: (DiskNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let kids = node.displayChildren(limit: 60)
            let tiles = Treemap.layout(kids.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.index) { t in
                    let n = kids[t.index]
                    let color = Color(hue: Double(t.index % 12) / 12.0, saturation: n.isDirectory ? 0.55 : 0.25, brightness: 0.85)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.85))
                        RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.15))
                        if t.rect.width > 60 && t.rect.height > 30 {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Text(Bytes.format(n.size)).font(.system(size: 10))
                            }.foregroundColor(.black.opacity(0.8)).padding(5)
                        }
                    }
                    .frame(width: max(1, t.rect.width - 2), height: max(1, t.rect.height - 2))
                    .offset(x: t.rect.minX + 1, y: t.rect.minY + 1)
                    .onHover { inside in hovered = inside ? "\(n.name) · \(Bytes.format(n.size))" : nil }
                    .onTapGesture { open(n) }
                    .help("\(n.path)\n\(Bytes.format(n.size))")
                }
            }
        }
    }
}

struct SpaceList: View {
    let node: DiskNode
    let open: (DiskNode) -> Void
    let rescan: () -> Void

    var body: some View {
        List(node.displayChildren(limit: 200)) { n in
            HStack {
                Image(nsImage: IconCache.icon(for: n.path)).resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.name).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(Color.accentColor.opacity(0.6))
                            .frame(width: g.size.width * CGFloat(Double(n.size) / Double(max(1, node.size))))
                    }.frame(height: 4)
                }
                Spacer()
                Text(Bytes.format(n.size)).font(.caption).monospacedDigit().foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(n) }
            .contextMenu {
                if n.isDirectory { Button("Open") { open(n) } }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)]) }
                Button("Move to Trash…") {
                    if FileRemover.shared.removeWithConfirmation([URL(fileURLWithPath: n.path)], module: "Space Lens",
                                                                  reason: "You chose this in Space Lens.") != nil { rescan() }
                }
            }
        }
    }
}

// MARK: - Login items

final class LoginItemsModel: ObservableObject {
    @Published var items: [LaunchItem] = []
    @Published var legacy: [String] = []

    func load() {
        items = LaunchItems.load()
        DispatchQueue.global(qos: .utility).async {
            let l = LaunchItems.loginItemNames()
            DispatchQueue.main.async { self.legacy = l }
        }
    }
}

struct LoginItemsView: View {
    @StateObject private var m = LoginItemsModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .loginItems, subtitle: "Apps and helpers that start with your Mac. Turning one off keeps the file and can be undone.") {
                HStack {
                    Button("Open Login Items Settings") { Actions.openURLString("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }
                    Button("Refresh") { m.load() }
                }
            }
            List {
                if !m.legacy.isEmpty {
                    Section("Open at Login") {
                        ForEach(m.legacy, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                if LaunchItems.isPaxLoginItem(name) {
                                    Text("Protected (Pax)").font(.caption).foregroundColor(.secondary).help(PaxProtection.note)
                                } else {
                                    Button("Remove") { if LaunchItems.removeLoginItem(name) { m.load() } }
                                }
                            }
                        }
                    }
                }
                ForEach([LaunchItem.Domain.user, .allUsersAgent, .daemon], id: \.rawValue) { d in
                    let list = m.items.filter { $0.domain == d }
                    if !list.isEmpty {
                        Section(d.rawValue) {
                            ForEach(list) { item in LaunchRow(item: item) { m.load() } }
                        }
                    }
                }
            }
        }
        .onAppear { m.load() }
    }
}

struct LaunchRow: View {
    let item: LaunchItem
    let reload: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).lineLimit(1)
                Text(item.program ?? item.path).font(.caption).foregroundColor(item.programExists ? .secondary : .orange).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.isPax {
                Text("Protected (Pax)").font(.caption).foregroundColor(.secondary).help(PaxProtection.note)
            } else {
            if !item.programExists { Text("Program missing").font(.caption).foregroundColor(.orange) }
            Toggle("", isOn: Binding(get: { !item.disabled }, set: { on in
                if let err = LaunchItems.setEnabled(item, on) { Actions.info("Couldn't change \(item.label)", err) }
                reload()
            })).labelsHidden().toggleStyle(.switch).help(item.domain == .daemon ? "Needs an administrator password" : "")
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Security

final class SecurityModel: ObservableObject {
    @Published var report: SecurityReport?
    @Published var scanning = false
    @Published var showOK = false

    func scan() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SecurityScanner.scan()
            DispatchQueue.main.async { self.report = r; self.scanning = false }
        }
    }
}

struct SecurityView: View {
    @ObservedObject var state: CleanerState
    @StateObject private var m = SecurityModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .security, subtitle: "Checks the places adware and malware hide to start themselves, plus browser extensions and proxy settings. Every finding says why. Nothing is removed automatically.") {
                HStack {
                    Toggle("Show items without issues", isOn: $m.showOK).toggleStyle(.checkbox)
                    if m.report != nil { Button("Scan Again") { m.scan() } }
                }
            }
            if m.scanning { ScanningView(text: "Checking launch agents, daemons, extensions…") }
            else if let r = m.report {
                List {
                    Section("Summary") {
                        let bad = r.launch.filter { $0.finding.severity == .suspicious }.count + r.extensions.filter { $0.finding.severity == .suspicious }.count
                        Label(bad == 0 ? "No known adware or suspicious background items found." : "\(bad) suspicious item\(bad == 1 ? "" : "s") found. Read why below.",
                              systemImage: bad == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundColor(bad == 0 ? .green : .red)
                        if let p = r.proxy {
                            Label("A \(p) is set for your network. Adware uses this to watch or redirect browsing. If you didn't set it (or your company didn't), turn it off in System Settings › Network › Details › Proxies.",
                                  systemImage: "network.badge.shield.half.filled").foregroundColor(.orange)
                        }
                        if let x = r.xprotectVersion {
                            Text("Apple's built-in XProtect malware definitions: version \(x). Swoop adds explanations on top of it; it doesn't replace it.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Section("Background items") {
                        ForEach(r.launch.filter { m.showOK || $0.finding.severity != .info }) { pair in
                            FindingRow(finding: pair.finding, extra: pair.item.domain.rawValue) {
                                if pair.finding.isProtected || pair.item.isPax {
                                    Text("Protected (Pax)").font(.caption).foregroundColor(.secondary)
                                } else {
                                Button("Disable") { if let e = LaunchItems.setEnabled(pair.item, false) { Actions.info("Couldn't disable", e) }; m.scan() }
                                Button("Remove…") {
                                    guard Actions.confirm("Remove \(pair.item.label)?", pair.finding.reasons.joined(separator: "\n"), ok: "Remove", destructive: true) else { return }
                                    if let e = LaunchItems.remove(pair.item, reason: pair.finding.reasons.joined(separator: " ")) { Actions.info("Couldn't remove", e) }
                                    m.scan()
                                }
                                }
                            }
                        }
                    }
                    Section("Browser extensions") {
                        ForEach(r.extensions.filter { m.showOK || $0.finding.severity != .info }) { e in
                            FindingRow(finding: e.finding, extra: e.browser) {
                                Text("Remove it from \(e.browser)'s Extensions page.").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } else {
                StartView(text: "Look for adware, hijackers and suspicious background items. Takes a few seconds.", button: "Scan", action: m.scan)
            }
        }
        .onAppear { if state.autoStartModule == .security { state.autoStartModule = nil; m.scan() } }
        .onChange(of: state.autoStartToken) { _ in if state.autoStartModule == .security { state.autoStartModule = nil; m.scan() } }
    }
}

struct FindingRow<Content: View>: View {
    let finding: SecurityFinding
    let extra: String
    @ViewBuilder var actions: Content

    var color: Color {
        switch finding.severity {
        case .info: return .green
        case .review: return .orange
        case .suspicious: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(finding.severity.title).font(.caption.weight(.bold)).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(color))
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.body.weight(.medium))
                ForEach(finding.reasons, id: \.self) { Text("• " + $0).font(.caption).fixedSize(horizontal: false, vertical: true) }
                Text(extra + " · " + (finding.path as NSString).abbreviatingWithTildeInPath).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack { actions }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
        }.padding(.vertical, 3)
    }
}

// MARK: - Updates

final class UpdatesModel: ObservableObject {
    @Published var rows: [UpdateChecker.Row] = []
    @Published var running = false
    @Published var progress = (0, 0)
    @Published var showAll = false

    func check() {
        running = true
        UpdateChecker.check(progress: { d, t in self.progress = (d, t) }) { r in self.rows = r; self.running = false }
    }
}

struct UpdatesView: View {
    @ObservedObject var state: CleanerState
    @StateObject private var m = UpdatesModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .updates, subtitle: "Checks each app's Sparkle update feed, the App Store, and Homebrew's cask index. Swoop never installs anything by itself.") {
                HStack {
                    Toggle("Show all apps", isOn: $m.showAll).toggleStyle(.checkbox)
                    if !m.rows.isEmpty { Button("Check Again") { m.check() } }
                }
            }
            if m.running { ScanningView(text: "Checked \(m.progress.0) of \(m.progress.1) apps…") }
            else if m.rows.isEmpty { StartView(text: "Find out which apps have newer versions.", button: "Check for Updates", action: m.check) }
            else {
                List(m.rows.filter { m.showAll || $0.hasUpdate }) { r in
                    HStack {
                        Image(nsImage: IconCache.icon(for: r.app.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading) {
                            Text(r.app.name)
                            Text(r.latest.map { "\(r.installed) → \($0)" } ?? "\(r.installed) · no update source")
                                .font(.caption).foregroundColor(r.hasUpdate ? .accentColor : .secondary)
                        }
                        Spacer()
                        if let s = r.source { Text(s.rawValue).font(.caption).foregroundColor(.secondary) }
                        if r.hasUpdate { updateButton(r) }
                    }
                }
                if !m.rows.contains(where: { $0.hasUpdate }) && !m.showAll {
                    Text("Everything is up to date.").foregroundColor(.secondary).padding()
                }
            }
        }
        .onAppear { if state.autoStartModule == .updates { state.autoStartModule = nil; m.check() } }
        .onChange(of: state.autoStartToken) { _ in if state.autoStartModule == .updates { state.autoStartModule = nil; m.check() } }
    }

    @ViewBuilder func updateButton(_ r: UpdateChecker.Row) -> some View {
        switch r.source {
        case .appStore?:
            Button("App Store") { Actions.openURLString(r.url?.replacingOccurrences(of: "https://", with: "macappstore://") ?? "macappstore://showUpdatesPage") }
        case .homebrew?:
            Button("brew upgrade") {
                let cmd = "brew upgrade --cask \(r.caskToken ?? "")"
                if UpdateChecker.brewPath != nil {
                    AppleScript.run("tell application \"Terminal\" to do script \"\(cmd)\"")
                    AppleScript.run("tell application \"Terminal\" to activate")
                } else {
                    Actions.copy(cmd)
                    Actions.info("Homebrew isn't installed", "The command was copied. Or download the update from \(r.url ?? "the developer's site").")
                }
            }
        default:
            Button("Update in App") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: r.app.path), configuration: NSWorkspace.OpenConfiguration()) }
                .help("Sparkle apps offer the update when they open (or via the app menu › Check for Updates).")
        }
    }
}

// MARK: - Maintenance

struct MaintenanceView: View {
    @State private var tick = 0

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .maintenance, subtitle: "Standard macOS fixes, explained. Tasks marked with a lock ask for your administrator password.")
            List(MaintenanceTask.all) { t in
                HStack(alignment: .top) {
                    Image(systemName: t.needsAdmin ? "lock.fill" : "wrench").foregroundColor(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.title).font(.body.weight(.medium))
                        Text(t.explanation).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let d = MaintenanceLog.lastRun(t.id) {
                            Text("Last run \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Run") { Maintenance.run(t); tick += 1 }
                }.padding(.vertical, 4)
            }
            .id(tick)
        }
    }
}

// MARK: - Privacy

struct PrivacyView: View {
    @State private var chosen = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .privacy, subtitle: "Clear traces of what you opened and browsed. Everything here is off until you tick it, and goes to the Trash so it can be restored.")
            PermissionInlineNote(feature: .protectedFolders).padding(.horizontal)
            List(PrivacyCleaner.items) { item in
                let existing = PrivacyCleaner.existing(item)
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { chosen.contains(item.id) }, set: { v in if v { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(existing.isEmpty)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                        Text(item.explanation).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        if existing.isEmpty { Text("Nothing found (or Full Disk Access is needed).").font(.caption2).foregroundColor(.secondary) }
                        if let b = PrivacyCleaner.runningBrowser(item) { Text("Quit \(b) first.").font(.caption2).foregroundColor(.orange) }
                    }
                }.padding(.vertical, 3)
            }
            HStack {
                Spacer()
                Button("Clear Selected…") {
                    let items = PrivacyCleaner.items.filter { chosen.contains($0.id) }
                    if let running = items.compactMap({ PrivacyCleaner.runningBrowser($0) }).first {
                        Actions.info("Quit \(running) first", "Its history file is in use while it's open.")
                        return
                    }
                    var reasons: [URL: String] = [:]
                    var urls: [URL] = []
                    for i in items { for u in PrivacyCleaner.existing(i) { urls.append(u); reasons[u] = i.explanation } }
                    if FileRemover.shared.removeWithConfirmation(urls, module: "Privacy", reason: "Privacy clean-up", reasons: reasons) != nil {
                        chosen = []
                    }
                }.disabled(chosen.isEmpty).controlSize(.large)
            }.padding(.horizontal, 24).padding(.vertical, 14).background(.bar)
        }
    }
}

// MARK: - Cloud storage

final class CloudStorageModel: ObservableObject {
    @Published var driveUsage: CloudUsage?
    @Published var driveFiles: [CloudFile] = []
    @Published var icloudUsage: CloudUsage?
    @Published var icloudFiles: [CloudFile] = []
    @Published var loading = false

    func load() {
        loading = true
        let c = CloudManager.shared
        if c.drive.isSignedIn {
            c.drive.usage { u in DispatchQueue.main.async { self.driveUsage = u } }
            c.drive.largeFiles { f in DispatchQueue.main.async { self.driveFiles = f } }
        }
        if c.icloud.isSignedIn {
            c.icloud.usage { u in DispatchQueue.main.async { self.icloudUsage = u } }
            c.icloud.largeFiles { f in DispatchQueue.main.async { self.icloudFiles = f; self.loading = false } }
        } else { loading = false }
    }
}

struct CloudStorageView: View {
    @StateObject private var m = CloudStorageModel()
    @ObservedObject private var drive = CloudManager.shared.drive

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .cloud, subtitle: "How much space your cloud storage uses and the biggest files in it. Swoop only reads your Drive; it never deletes cloud files.") {
                Button("Refresh") { m.load() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Google Drive", systemImage: "externaldrive.connected.to.line.below").font(.headline)
                                Spacer()
                                if drive.isSignedIn {
                                    Text(drive.accountName ?? "Signed in").foregroundColor(.secondary)
                                    Button("Sign Out") { drive.signOut(); m.driveUsage = nil; m.driveFiles = [] }
                                } else {
                                    Button(drive.signingIn ? "Waiting for browser…" : "Sign In") { drive.signIn() }.disabled(drive.signingIn)
                                }
                            }
                            if let u = m.driveUsage { UsageBar(usage: u, trashLabel: "in Drive's Trash") }
                            ForEach(m.driveFiles.prefix(25)) { f in CloudFileRow(file: f) }
                            if !drive.isSignedIn {
                                Text("Sign in to see usage and your largest files, search Drive from Swoop, and upload with one command.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }.padding(6)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("iCloud Drive", systemImage: "icloud").font(.headline)
                                Spacer()
                                Button("Open Folder") { CloudManager.shared.openICloudFolder() }
                            }
                            if let u = m.icloudUsage {
                                Text("\(Bytes.format(u.used)) in iCloud Drive · \(Bytes.format(u.inTrash ?? 0)) downloaded to this Mac")
                                    .foregroundColor(.secondary)
                                Text("Apple doesn't let apps read your iCloud plan size; see System Settings › Apple ID › iCloud.")
                                    .font(.caption).foregroundColor(.secondary)
                            } else if !CloudManager.shared.icloud.isSignedIn {
                                Text("iCloud Drive isn't turned on for this Mac.").foregroundColor(.secondary)
                            }
                            ForEach(m.icloudFiles.prefix(25)) { f in CloudFileRow(file: f) }
                        }.padding(6)
                    }
                    GroupBox {
                        HStack {
                            Label("Dropbox and OneDrive", systemImage: "plus.circle").font(.headline)
                            Spacer()
                            Text("Coming next. Same sign-in and search as Google Drive.").foregroundColor(.secondary)
                        }.padding(6)
                    }
                }.padding(24)
            }
        }
        .onAppear { m.load() }
    }
}

struct UsageBar: View {
    let usage: CloudUsage
    let trashLabel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let f = usage.fraction { ProgressView(value: f).tint(f > 0.9 ? .red : .accentColor) }
            Text("\(Bytes.format(usage.used)) used" + (usage.limit.map { " of \(Bytes.format($0))" } ?? "")
                 + ((usage.inTrash ?? 0) > 0 ? " · \(Bytes.format(usage.inTrash ?? 0)) \(trashLabel)" : ""))
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

struct CloudFileRow: View {
    let file: CloudFile
    var body: some View {
        HStack {
            Image(systemName: "doc").foregroundColor(.secondary)
            Text(file.name).lineLimit(1)
            Spacer()
            Text(file.size.map { Bytes.format($0) } ?? "").font(.caption).monospacedDigit().foregroundColor(.secondary)
            if let w = file.webURL { Button("Open") { Actions.openURLString(w) }.buttonStyle(.link) }
            if let l = file.localPath {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: l)]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Battery

struct BatteryView: View {
    @State private var health: BatteryHealth?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .battery, subtitle: "Read straight from the battery's own controller. No settings are changed.") {
                Button("Refresh") { load() }
            }
            if !loaded { ScanningView(text: "Reading the battery…") }
            else if let b = health {
                Form {
                    if let h = b.healthPercent {
                        LabeledContent("Maximum capacity") { Text("\(h)% of new").foregroundColor(h < 80 ? .orange : .primary) }
                    }
                    if let c = b.cycleCount { LabeledContent("Charge cycles") { Text("\(c)") } }
                    if let c = b.condition { LabeledContent("Condition") { Text(c).foregroundColor(c == "Normal" ? .green : .orange) } }
                    if let c = b.currentCharge { LabeledContent("Charge now") { Text("\(c)%" + (b.isCharging ? " · charging" : "")) } }
                    if let t = b.temperatureC { LabeledContent("Temperature") { Text(String(format: "%.1f °C", t)) } }
                    Section {
                        Text("Batteries are considered worn below 80% of their original capacity. Most Mac batteries are rated for 1,000 cycles. Optimised Battery Charging (System Settings › Battery) slows wear by holding at 80% when you're usually plugged in.")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.formStyle(.grouped)
            } else {
                StartView(text: "This Mac doesn't have a battery.", button: "Check Again") { load() }
            }
        }
        .onAppear { if !loaded { load() } }
    }

    func load() {
        loaded = false
        DispatchQueue.global(qos: .userInitiated).async {
            let b = BatteryReader.read()
            DispatchQueue.main.async { health = b; loaded = true }
        }
    }
}

// MARK: - Restore

struct RestoreView: View {
    @ObservedObject private var remover = FileRemover.shared

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .restore, subtitle: "Everything Swoop has removed, with the reason it gave at the time. Items moved to the Trash can be put back where they were.")
            if remover.log.records.isEmpty {
                StartView(text: "Nothing removed yet.", button: "Open Smart Scan") { CleanerWindow.show(.smartScan) }
            } else {
                List {
                    ForEach(Array(remover.log.sessions().prefix(100).enumerated()), id: \.offset) { _, session in
                        Section {
                            ForEach(session) { r in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((r.originalPath as NSString).lastPathComponent).lineLimit(1)
                                        Text((r.originalPath as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(Bytes.format(r.size)).font(.caption).foregroundColor(.secondary)
                                    WhySafe(note: r.reason)
                                    if r.restored { Text("Restored").font(.caption).foregroundColor(.green) }
                                    else if r.canRestore { Button("Put Back") { restore([r]) } }
                                    else { Text(r.trashedPath == nil ? "Deleted" : "—").font(.caption).foregroundColor(.secondary) }
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(session.first?.module ?? "") · \(session.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "")")
                                Spacer()
                                Text(Bytes.format(session.reduce(0) { $0 + $1.size }))
                                if session.contains(where: { $0.canRestore }) {
                                    Button("Put Back All") { restore(session.filter { $0.canRestore }) }.buttonStyle(.link)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func restore(_ records: [RemovalRecord]) {
        var errors: [String] = []
        for r in records { if let e = remover.restore(r) { errors.append("\((r.originalPath as NSString).lastPathComponent): \(e)") } }
        if errors.isEmpty { Notifier.show("Restored \(records.count) item\(records.count == 1 ? "" : "s")") }
        else { Actions.info("Some items couldn't be restored", errors.prefix(8).joined(separator: "\n")) }
    }
}
