// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import SwoopCore

// MARK: - Smart Scan

final class SmartScanModel: ObservableObject {
    @Published var running = false
    @Published var done = false
    @Published var status = ""
    @Published var items: [CleanItem] = []
    @Published var suspicious = 0
    @Published var review = 0
    @Published var updates: Int?
    @Published var largeCount = 0
    @Published var largeBytes: Int64 = 0

    func start() {
        guard !running else { return }
        running = true; done = false; items = []
        DispatchQueue.global(qos: .userInitiated).async {
            let junk = JunkScanner.scan(rules: JunkScanner.enabledRules) { t in DispatchQueue.main.async { self.status = "Junk: \(t)" } }
            DispatchQueue.main.async { self.status = "Leftovers of deleted apps…" }
            let orphans = Uninstaller.orphans().map { i in
                CleanItem(url: i.url, size: i.size, group: "Leftovers of deleted apps", note: i.note, selected: false, detail: i.detail)
            }
            DispatchQueue.main.async { self.status = "Security check…" }
            let sec = SecurityScanner.scan()
            DispatchQueue.main.async { self.status = "Large files in your home folder…" }
            let large = LargeFileScanner.scan(root: FileManager.default.homeDirectoryForCurrentUser, minBytes: 1_000_000_000)
            DispatchQueue.main.async {
                self.items = junk + orphans
                self.suspicious = sec.launch.filter { $0.finding.severity == .suspicious }.count
                    + sec.extensions.filter { $0.finding.severity == .suspicious }.count
                self.review = sec.launch.filter { $0.finding.severity == .review }.count
                self.largeCount = large.count
                self.largeBytes = large.reduce(0) { $0 + $1.size }
                self.status = "Checking for app updates…"
                UpdateChecker.check(progress: { _, _ in }) { rows in
                    self.updates = rows.filter { $0.hasUpdate }.count
                    self.running = false
                    self.done = true
                }
            }
        }
    }
}

struct SmartScanView: View {
    @ObservedObject var state: CleanerState
    @StateObject private var m = SmartScanModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .smartScan, subtitle: "Junk, leftovers, security, large files and updates in one pass. Nothing is removed until you review it.") {
                if m.done { Button("Scan Again") { m.start() } }
            }
            if m.running && m.items.isEmpty {
                ScanningView(text: m.status)
            } else if !m.done && m.items.isEmpty {
                StartView(text: "Smart Scan checks System Junk, leftovers from deleted apps, background items for adware, files over 1 GB, and app updates.",
                          button: "Scan", action: m.start)
            } else {
                HStack(spacing: 12) {
                    SummaryCard(title: "Junk to clean", value: Bytes.format(m.items.filter { $0.selected }.reduce(0) { $0 + $1.size }),
                                symbol: "trash.circle", color: .blue) { state.module = .junk }
                    SummaryCard(title: "Security", value: m.suspicious > 0 ? "\(m.suspicious) suspicious" : (m.review > 0 ? "\(m.review) to review" : "No threats"),
                                symbol: "shield.lefthalf.filled", color: m.suspicious > 0 ? .red : .green) { state.module = .security }
                    SummaryCard(title: "Large files", value: "\(m.largeCount) · \(Bytes.format(m.largeBytes))", symbol: "doc.zipper",
                                color: .orange) { state.module = .largeFiles }
                    SummaryCard(title: "App updates", value: m.updates.map { "\($0) available" } ?? "Checking…",
                                symbol: "arrow.down.app", color: .purple) { state.module = .updates }
                }
                .padding(.horizontal, 24).padding(.bottom, 8)
                CleanItemList(items: $m.items)
                CleanBar(items: m.items, buttonTitle: "Clean", busy: m.running) {
                    if CleanRunner.clean(m.items, module: "Smart Scan") != nil { m.items.removeAll { $0.selected } }
                }
            }
        }
        .onAppear { if state.autoStartModule == .smartScan { state.autoStartModule = nil; m.start() } }
        .onChange(of: state.autoStartToken) { _ in if state.autoStartModule == .smartScan { state.autoStartModule = nil; m.start() } }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundColor(color)
                Text(value).font(.headline).lineLimit(1)
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        }.buttonStyle(.plain)
    }
}

// MARK: - System Junk

final class JunkModel: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var status = ""

    func scan() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = JunkScanner.scan(rules: JunkScanner.enabledRules) { t in DispatchQueue.main.async { self.status = t } }
            DispatchQueue.main.async { self.items = found; self.scanning = false; self.scanned = true }
        }
    }
}

struct JunkView: View {
    @ObservedObject var state: CleanerState
    @StateObject private var m = JunkModel()
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .junk, subtitle: "Caches, logs, Xcode build products and unfinished downloads. Apple's own caches are never touched.") {
                HStack {
                    Menu("Categories") {
                        ForEach(JunkRules.all) { r in
                            Toggle(r.title, isOn: Binding(get: { prefs.enabledJunkRules.contains(r.id) }, set: { on in
                                if on { prefs.enabledJunkRules.append(r.id) } else { prefs.enabledJunkRules.removeAll { $0 == r.id } }
                            }))
                        }
                    }
                    if m.scanned { Button("Rescan") { m.scan() } }
                }
            }
            if m.scanning { ScanningView(text: m.status) }
            else if !m.scanned { StartView(text: "Scan for junk in \(JunkScanner.enabledRules.count) places. You'll review everything before anything is removed.", button: "Scan", action: m.scan) }
            else {
                CleanItemList(items: $m.items, emptyText: "Your Mac is clean.")
                HStack {
                    Image(systemName: "calendar.badge.clock").foregroundColor(.secondary)
                    Text(prefs.schedule.frequency == .off ? "Automatic clean-ups are off." : "Automatic clean-up: \(prefs.schedule.frequency.rawValue).")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Schedule…") { SettingsWindow.show(tab: .cleaner) }.buttonStyle(.link).font(.caption)
                    Spacer()
                }.padding(.horizontal, 24).padding(.top, 6)
                CleanBar(items: m.items, buttonTitle: "Clean") {
                    if CleanRunner.clean(m.items, module: "System Junk") != nil { m.items.removeAll { $0.selected } }
                }
            }
        }
        .onAppear { if state.autoStartModule == .junk { state.autoStartModule = nil; m.scan() } }
        .onChange(of: state.autoStartToken) { _ in if state.autoStartModule == .junk { state.autoStartModule = nil; m.scan() } }
    }
}

// MARK: - Large & Old Files

final class LargeFilesModel: ObservableObject {
    @Published var all: [FoundFile] = []
    @Published var selected = Set<String>()
    @Published var scanning = false
    @Published var scanned = false
    @Published var count = 0
    @Published var filter = LargeFileFilter(minBytes: 100_000_000, olderThanDays: 0, kind: .all)
    private var cancel = CancelToken()

    var visible: [FoundFile] { all.filter { filter.matches(path: $0.path, size: $0.size, lastUsed: $0.lastUsed) } }

    func scan() {
        cancel.cancel(); cancel = CancelToken()
        let c = cancel
        scanning = true; selected = []
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LargeFileScanner.scan(root: FileManager.default.homeDirectoryForCurrentUser, minBytes: 20_000_000, cancel: c) { n in
                DispatchQueue.main.async { self.count = n }
            }
            DispatchQueue.main.async { self.all = found; self.scanning = false; self.scanned = true }
        }
    }
}

struct LargeFilesView: View {
    @ObservedObject var state: CleanerState
    @StateObject private var m = LargeFilesModel()
    let sizes: [(String, Int64)] = [("20 MB", 20_000_000), ("100 MB", 100_000_000), ("500 MB", 500_000_000), ("1 GB", 1_000_000_000), ("5 GB", 5_000_000_000)]
    let ages: [(String, Int)] = [("Any age", 0), ("Unused 1 month", 30), ("Unused 6 months", 182), ("Unused 1 year", 365), ("Unused 2 years", 730)]

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .largeFiles, subtitle: SafetyNotes.largeFile) {
                if m.scanned { Button("Rescan") { m.scan() } }
            }
            HStack {
                Picker("Size", selection: $m.filter.minBytes) { ForEach(sizes.indices, id: \.self) { i in Text("Over " + sizes[i].0).tag(sizes[i].1) } }.frame(width: 180)
                Picker("Age", selection: $m.filter.olderThanDays) { ForEach(ages.indices, id: \.self) { i in Text(ages[i].0).tag(ages[i].1) } }.frame(width: 200)
                Picker("Kind", selection: $m.filter.kind) { ForEach(FileKind.allCases) { Text($0.title).tag($0) } }.frame(width: 220)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 8)
            if m.scanning { ScanningView(text: "Looked at \(m.count) files…") }
            else if !m.scanned { StartView(text: "Find big files in your home folder. Nothing is selected for you.", button: "Scan", action: m.scan) }
            else {
                List(m.visible) { f in
                    HStack {
                        Toggle("", isOn: Binding(get: { m.selected.contains(f.path) }, set: { v in if v { m.selected.insert(f.path) } else { m.selected.remove(f.path) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                        Image(nsImage: IconCache.icon(for: f.path)).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading) {
                            Text((f.path as NSString).lastPathComponent).lineLimit(1)
                            Text((f.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let d = f.lastUsed { Text(d, style: .date).font(.caption).foregroundColor(.secondary) }
                        Text(Bytes.format(f.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        Button { Actions.quickLook(URL(fileURLWithPath: f.path)) } label: { Image(systemName: "eye") }.buttonStyle(.borderless)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                    }
                }
                let sel = m.visible.filter { m.selected.contains($0.path) }
                HStack {
                    Text("\(m.visible.count) files · \(sel.count) selected · \(Bytes.format(sel.reduce(0) { $0 + $1.size }))").foregroundColor(.secondary)
                    Spacer()
                    Button("Remove…") {
                        let urls = sel.map { URL(fileURLWithPath: $0.path) }
                        if FileRemover.shared.removeWithConfirmation(urls, module: "Large & Old Files", reason: SafetyNotes.largeFile) != nil {
                            m.all.removeAll { m.selected.contains($0.path) && !FileManager.default.fileExists(atPath: $0.path) }
                            m.selected = []
                        }
                    }.disabled(sel.isEmpty).controlSize(.large)
                }.padding(.horizontal, 24).padding(.vertical, 14).background(.bar)
            }
        }
        .onAppear { if state.autoStartModule == .largeFiles { state.autoStartModule = nil; m.scan() } }
        .onChange(of: state.autoStartToken) { _ in if state.autoStartModule == .largeFiles { state.autoStartModule = nil; m.scan() } }
    }
}

// MARK: - Duplicates

final class DuplicatesModel: ObservableObject {
    @Published var folders: [URL] = ["Downloads", "Documents", "Desktop"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) }
    @Published var groups: [[FoundFile]] = []
    @Published var selected = Set<String>()
    @Published var scanning = false
    @Published var scanned = false
    @Published var status = ""

    func scan() {
        scanning = true
        let f = folders
        DispatchQueue.global(qos: .userInitiated).async {
            let g = DuplicateScanner.scan(folders: f) { s in DispatchQueue.main.async { self.status = s } }
            DispatchQueue.main.async {
                self.groups = g
                // Keep the oldest copy of each group; select the rest.
                self.selected = Set(g.flatMap { $0.dropFirst().map { $0.path } })
                self.scanning = false
                self.scanned = true
            }
        }
    }
}

struct DuplicatesView: View {
    @StateObject private var m = DuplicatesModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .duplicates, subtitle: SafetyNotes.duplicate) {
                if m.scanned { Button("Rescan") { m.scan() } }
            }
            HStack {
                Text("Folders: " + m.folders.map { $0.lastPathComponent }.joined(separator: ", ")).foregroundColor(.secondary).lineLimit(1)
                Button("Add Folder…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
                    if p.runModal() == .OK { m.folders += p.urls }
                }
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 6)
            if m.scanning { ScanningView(text: m.status.isEmpty ? "Reading files…" : m.status) }
            else if !m.scanned { StartView(text: "Find byte-for-byte identical files (over 100 KB).", button: "Scan", action: m.scan) }
            else if m.groups.isEmpty { StartView(text: "No duplicates found.", button: "Scan Again", action: m.scan) }
            else {
                List {
                    ForEach(Array(m.groups.enumerated()), id: \.offset) { _, g in
                        Section("\(g.count) copies · \(Bytes.format(g.first?.size ?? 0)) each") {
                            ForEach(g) { f in
                                HStack {
                                    Toggle("", isOn: Binding(get: { m.selected.contains(f.path) }, set: { v in if v { m.selected.insert(f.path) } else { m.selected.remove(f.path) } }))
                                        .labelsHidden().toggleStyle(.checkbox)
                                    Image(nsImage: IconCache.icon(for: f.path)).resizable().frame(width: 18, height: 18)
                                    Text((f.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if f.id == g.first?.id { Text("Kept (oldest)").font(.caption).foregroundColor(.green) }
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                let sel = m.groups.flatMap { $0 }.filter { m.selected.contains($0.path) }
                HStack {
                    Text("\(sel.count) selected · \(Bytes.format(sel.reduce(0) { $0 + $1.size }))").foregroundColor(.secondary)
                    Spacer()
                    Button("Remove Duplicates…") {
                        // Never remove every copy of a group.
                        let safe = m.groups.flatMap { g -> [FoundFile] in
                            let chosen = g.filter { m.selected.contains($0.path) }
                            return chosen.count == g.count ? Array(chosen.dropFirst()) : chosen
                        }
                        if FileRemover.shared.removeWithConfirmation(safe.map { URL(fileURLWithPath: $0.path) }, module: "Duplicates", reason: SafetyNotes.duplicate) != nil {
                            m.scan()
                        }
                    }.disabled(sel.isEmpty).controlSize(.large)
                }.padding(.horizontal, 24).padding(.vertical, 14).background(.bar)
            }
        }
    }
}

// MARK: - Uninstaller

final class UninstallerModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var search = ""
    @Published var selectedPath: String?
    @Published var target: UninstallTarget?
    @Published var loading = false
    @Published var tab = 0
    @Published var orphans: [CleanItem] = []
    @Published var orphansScanned = false
    @Published var sizes: [String: Int64] = [:]

    func load() {
        apps = Uninstaller.candidates()
        let list = apps
        DispatchQueue.global(qos: .utility).async {
            for a in list {
                let s = Sizer.size(of: URL(fileURLWithPath: a.path))
                DispatchQueue.main.async { self.sizes[a.path] = s }
            }
        }
    }

    func select(_ path: String) {
        selectedPath = path
        guard let app = apps.first(where: { $0.path == path }) ?? Providers.shared.installedApps.first(where: { $0.path == path }) else { return }
        if PaxGuardrails.isPaxApp(path: app.path, bundleID: app.bundleID) {
            selectedPath = nil
            Actions.info("Pax is protected", PaxProtection.note)
            return
        }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Uninstaller.leftovers(for: app)
            DispatchQueue.main.async { self.target = t; self.loading = false }
        }
    }

    func scanOrphans() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let o = Uninstaller.orphans()
            DispatchQueue.main.async { self.orphans = o; self.orphansScanned = true; self.loading = false }
        }
    }

    func uninstall() {
        guard var t = target else { return }
        if PaxGuardrails.isPaxApp(path: t.app.path, bundleID: t.app.bundleID) { return }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == t.app.path }) {
            guard Actions.confirm("Quit \(t.app.name)?", "It has to be closed before it can be removed.", ok: "Quit") else { return }
            running.terminate()
            Thread.sleep(forTimeInterval: 1.5)
            if !running.isTerminated { running.forceTerminate() }
        }
        // Stop its launch agents first so nothing respawns.
        for i in t.items where i.selected && i.url.path.contains("/LaunchAgents/") {
            if let label = (NSDictionary(contentsOf: i.url)?["Label"] as? String) {
                Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            }
        }
        if CleanRunner.clean(t.items, module: "Uninstaller") != nil {
            t.items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
            target = t.items.isEmpty ? nil : t
            Providers.shared.refreshApps(force: true)
            load()
        }
    }
}

struct UninstallerView: View {
    @ObservedObject var state: CleanerState
    @StateObject private var m = UninstallerModel()

    var filtered: [InstalledApp] {
        m.search.isEmpty ? m.apps : m.apps.filter { FuzzyMatcher.match(m.search, in: $0.name) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .uninstaller, subtitle: "Removes an app together with its settings, caches, containers, launch agents and saved state, matched by bundle ID.") {
                Picker("", selection: $m.tab) { Text("Apps").tag(0); Text("Leftovers of deleted apps").tag(1) }.pickerStyle(.segmented).frame(width: 320)
            }
            if m.tab == 0 {
                HSplitView {
                    VStack(spacing: 0) {
                        TextField("Search apps", text: $m.search).textFieldStyle(.roundedBorder).padding(8)
                        List(filtered, id: \.path, selection: Binding(get: { m.selectedPath }, set: { if let p = $0 { m.select(p) } })) { a in
                            HStack {
                                Image(nsImage: IconCache.icon(for: a.path)).resizable().frame(width: 22, height: 22)
                                Text(a.name).lineLimit(1)
                                Spacer()
                                if let s = m.sizes[a.path] { Text(Bytes.format(s)).font(.caption).foregroundColor(.secondary) }
                            }.tag(a.path as String?)
                        }
                    }.frame(minWidth: 260, idealWidth: 290)
                    VStack(spacing: 0) {
                        if m.loading { ScanningView(text: "Finding leftovers…") }
                        else if let t = m.target {
                            CleanItemList(items: Binding(get: { m.target?.items ?? [] }, set: { m.target?.items = $0 }))
                            CleanBar(items: t.items, buttonTitle: "Uninstall \(t.app.name)") { m.uninstall() }
                        } else {
                            StartView(text: "Choose an app to see everything that belongs to it.", button: "Refresh List") { m.load() }
                        }
                    }.frame(minWidth: 420)
                }
            } else {
                if m.loading { ScanningView(text: "Checking your Library against installed apps…") }
                else if !m.orphansScanned { StartView(text: SafetyNotes.orphan, button: "Find Leftovers", action: m.scanOrphans) }
                else {
                    CleanItemList(items: $m.orphans, emptyText: "No leftovers from deleted apps.")
                    CleanBar(items: m.orphans, buttonTitle: "Remove Leftovers") {
                        if CleanRunner.clean(m.orphans, module: "Uninstaller (leftovers)") != nil { m.orphans.removeAll { $0.selected } }
                    }
                }
            }
        }
        .onAppear {
            m.load()
            if let p = state.pendingAppPath { state.pendingAppPath = nil; m.select(p) }
        }
        .onChange(of: state.pendingAppPath) { p in if let p = p { state.pendingAppPath = nil; m.tab = 0; m.select(p) } }
    }
}
