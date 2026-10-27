// SPDX-License-Identifier: MIT
import AppKit
import SafariServices
import ShieldCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Shield.
struct ShieldSettings: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", log = "Query Log", lists = "Filter Lists", rules = "My Rules", browsers = "Browsers", advanced = "Advanced"
        var id: String { rawValue }
    }
    @ObservedObject private var shield = ShieldController.shared
    @State private var section: Section = .overview

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 4)
            Group {
                switch section {
                case .overview: ShieldOverview()
                case .log: ShieldLogView()
                case .lists: ShieldListsView()
                case .rules: ShieldRulesView()
                case .browsers: ShieldBrowsersView()
                case .advanced: ShieldAdvancedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { shield.uiVisible = true }
        .onDisappear { shield.uiVisible = false }
    }
}

// MARK: - Overview

struct ShieldOverview: View {
    @ObservedObject private var shield = ShieldController.shared
    @State private var newSite = ""
    @State private var siteMinutes = 0

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: shield.config.enabled ? "shield.lefthalf.filled" : "shield.slash")
                        .font(.system(size: 34)).foregroundColor(statusColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Swoop Shield").font(.title2.weight(.semibold))
                        Text(statusText).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { shield.config.enabled }, set: { shield.setEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if case .needsApproval = shield.status {
                    HStack {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        Button("Check Again") { shield.setEnabled(true) }
                    }
                }
                if shield.config.enabled {
                    HStack(spacing: 24) {
                        stat("\(shield.stats?.blockedToday ?? 0)", "blocked today")
                        stat("\(shield.stats?.queriesToday ?? 0)", "lookups today")
                        stat(String(format: "%.1f%%", shield.stats?.blockedPercentToday ?? 0), "blocked")
                        stat("\(shield.stats?.cnameBlockedTotal ?? 0)", "cloaked trackers")
                        stat("\(shield.stats?.bypassBlockedTotal ?? 0)", "DNS bypasses stopped")
                    }
                    .padding(.vertical, 4)
                    HStack {
                        if shield.config.isPaused(at: Date()) {
                            Button("Resume Now") { shield.resume() }
                        } else {
                            Menu("Pause Ad Blocking") {
                                Button("For 5 minutes") { shield.pause(minutes: 5) }
                                Button("For 15 minutes") { shield.pause(minutes: 15) }
                                Button("For 1 hour") { shield.pause(minutes: 60) }
                                Button("Until tomorrow") { shield.pause(minutes: minutesUntilTomorrow()) }
                            }.fixedSize()
                        }
                    }
                }
            }

            Section("Protection") {
                Picker("Mode", selection: Binding(get: { shield.mode }, set: { shield.switchMode(to: $0) })) {
                    ForEach(ShieldMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(shield.mode.detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if shield.mode == .systemExtension && !shield.systemExtensionAvailable {
                    Text("This build doesn't include the signed system extension (it needs a Developer ID build with the Network Extension entitlement). Local resolver gives you the same filtering.")
                        .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if shield.mode == .encryptedProfile {
                    Picker("Provider", selection: $shield.profileProvider) {
                        ForEach(DNSProfileBuilder.providers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if let p = DNSProfileBuilder.providers.first(where: { $0.id == shield.profileProvider }) {
                        Text(p.note).font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Section("Top blocked") {
                if let top = shield.stats?.topBlocked, !top.isEmpty {
                    ForEach(top.prefix(12)) { t in
                        HStack {
                            Text(t.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(t.count)").monospacedDigit().foregroundColor(.secondary)
                            Button("Allow") { shield.allow(site: t.name) }.buttonStyle(.borderless)
                        }
                    }
                } else {
                    Text("Nothing blocked yet.").foregroundColor(.secondary)
                }
            }

            if let apps = shield.stats?.topApps, !apps.isEmpty {
                Section("Apps with the most blocked lookups") {
                    ForEach(apps.prefix(8)) { a in
                        HStack { Text(appName(a.name)); Spacer(); Text("\(a.count)").monospacedDigit().foregroundColor(.secondary) }
                    }
                }
            }

            Section("Paused for apps and sites") {
                ForEach(shield.config.appPauses) { p in
                    HStack {
                        Label(p.name, systemImage: "app")
                        Spacer()
                        Text(untilText(p.until)).foregroundColor(.secondary)
                        Button("Remove") { shield.update { $0.appPauses.removeAll { $0.id == p.id } } }.buttonStyle(.borderless)
                    }
                }
                ForEach(shield.config.sitePauses) { p in
                    HStack {
                        Label(p.domain, systemImage: "globe")
                        Spacer()
                        Text(untilText(p.until)).foregroundColor(.secondary)
                        Button("Remove") { shield.update { $0.sitePauses.removeAll { $0.domain == p.domain } } }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Site, e.g. example.com", text: $newSite).textFieldStyle(.roundedBorder)
                    Picker("", selection: $siteMinutes) {
                        Text("Until I resume").tag(0); Text("1 hour").tag(60); Text("1 day").tag(1440)
                    }.labelsHidden().frame(width: 140)
                    Button("Pause Site") {
                        shield.pause(site: newSite, minutes: siteMinutes == 0 ? nil : siteMinutes)
                        newSite = ""
                    }.disabled(DomainName.host(fromURLOrHost: newSite) == nil)
                }
                Button("Pause for an App…") { pickApp() }
                Text("An app pause lets that app's lookups through when macOS tells Shield which app asked (system extension mode). A site pause lets the site's own domain through everywhere; the browser extensions also stop blocking on its pages.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Label("Everything stays on this Mac: lists are downloaded from their maintainers, the query log is stored locally and never uploaded, and Swoop has no telemetry.", systemImage: "lock")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch shield.status {
        case .off: return shield.config.enabled ? "Starting…" : "Off. Turn on to block ads, trackers and malware in every app and browser."
        case .starting(let s), .needsApproval(let s), .problem(let s): return s
        case .active(let s): return "On · \(s)"
        case .paused(let u): return "Paused until \(DateFormatter.localizedString(from: u, dateStyle: .none, timeStyle: .short))"
        }
    }

    private var statusColor: Color {
        switch shield.status {
        case .active: return .green
        case .paused, .needsApproval, .starting: return .orange
        case .problem: return .red
        case .off: return .secondary
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }

    private func untilText(_ d: Date?) -> String {
        guard let d = d else { return "until you resume" }
        return "until " + DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
    }

    private func minutesUntilTomorrow() -> Int {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: Date().addingTimeInterval(86_400)).addingTimeInterval(6 * 3600)
        return max(5, Int(tomorrow.timeIntervalSinceNow / 60))
    }

    private func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let u = p.url, let b = Bundle(url: u), let id = b.bundleIdentifier else { return }
        let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? u.deletingPathExtension().lastPathComponent
        shield.pause(app: id, name: name, minutes: nil)
    }
}

func appName(_ bundleID: String) -> String {
    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundleID
}

// MARK: - Query log

struct ShieldLogView: View {
    enum Filter: String, CaseIterable { case all = "All", blocked = "Blocked", allowed = "Allowed" }
    @ObservedObject private var shield = ShieldController.shared
    @State private var search = ""
    @State private var filter: Filter = .all

    private var rows: [QueryLogEntry] {
        shield.log.reversed().filter { e in
            (filter == .all || (filter == .blocked ? e.action == .blocked : e.action == .allowed))
                && (search.isEmpty || e.name.localizedCaseInsensitiveContains(search) || (e.app ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Keep a query log", isOn: Binding(get: { shield.config.logQueries }, set: { v in shield.update { $0.logQueries = v } }))
                Picker("Keep for", selection: Binding(get: { shield.config.logRetentionHours }, set: { v in shield.update { $0.logRetentionHours = v } })) {
                    Text("1 hour").tag(1); Text("24 hours").tag(24); Text("7 days").tag(168)
                }.frame(width: 170)
                Spacer()
                Button("Clear") { shield.clearLog() }
            }
            HStack {
                TextField("Search domains or apps", text: $search).textFieldStyle(.roundedBorder)
                Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            Table(rows) {
                TableColumn("Time") { e in Text(DateFormatter.localizedString(from: e.time, dateStyle: .none, timeStyle: .medium)).monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn("Domain") { e in
                    Text(e.name).foregroundColor(e.action == .blocked ? .red : .primary).lineLimit(1).truncationMode(.middle)
                        .contextMenu {
                            Button("Allow \(DomainName.registrableDomain(e.name))") { shield.allow(site: e.name) }
                            Button("Block \(e.name)") { shield.block(site: e.name) }
                            Button("Copy") { Actions.copy(e.name) }
                        }
                }.width(min: 180, ideal: 260)
                TableColumn("Type") { e in Text(e.type).foregroundColor(.secondary) }.width(min: 40, ideal: 50)
                TableColumn("App") { e in Text(e.app.map(appName) ?? "").lineLimit(1) }.width(min: 80, ideal: 120)
                TableColumn("Result") { e in
                    Text(resultText(e)).foregroundColor(e.action == .blocked ? .red : (e.action == .allowed ? .green : .secondary)).lineLimit(1)
                        .help(e.rule ?? "")
                }.width(min: 120, ideal: 200)
            }
            Text(shield.config.logQueries
                 ? "Stored only on this Mac and deleted after \(shield.config.logRetentionHours) h. Right-click a domain to allow or block it."
                 : "The query log is off. Counters and top-blocked lists still work.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(16)
    }

    private func resultText(_ e: QueryLogEntry) -> String {
        switch e.action {
        case .blocked:
            if let c = e.cname { return "Blocked · cloaked (\(c))" }
            return "Blocked · \(listName(e.source))"
        case .allowed: return "Allowed · \(listName(e.source))"
        case .passed: return e.note.map { "Passed (\($0))" } ?? "Passed"
        }
    }
}

func listName(_ source: String?) -> String {
    guard let s = source else { return "" }
    switch s {
    case "allowlist": return "your allowlist"
    case "custom": return "your rules"
    case "doh-policy": return "encrypted-DNS bypass"
    case "cname": return "cloaked tracker"
    case "site-pause": return "site paused"
    case "filter": return "connection filter"
    default: return FilterListCatalog.source(id: s)?.name ?? s
    }
}

// MARK: - Filter lists

struct ShieldListsView: View {
    @ObservedObject private var shield = ShieldController.shared
    @ObservedObject private var lists = ShieldController.shared.lists

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        if let r = lists.report {
                            Text("\(r.dnsDomains.formatted()) domains for system-wide blocking · \(r.safariRules.formatted()) Safari rules · \(r.dnrRules.formatted()) Chrome/Firefox rules")
                        }
                        Text(lists.compiledAt.map { "Compiled \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())). Lists refresh about once a day." }
                             ?? "Lists haven't been downloaded yet.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if lists.isUpdating { ProgressView().controlSize(.small) }
                    Button("Update Lists") { lists.update(force: true) }.disabled(lists.isUpdating)
                }
            }
            ForEach(ListCategory.allCases, id: \.self) { cat in
                let items = FilterListCatalog.all.filter { $0.category == cat }
                if !items.isEmpty {
                    Section(cat.rawValue) {
                        ForEach(items) { l in row(l) }
                    }
                }
            }
            Section {
                Text("Each list is downloaded directly from its maintainer and keeps its own licence; Swoop doesn't redistribute them. Every download is checked (size, format, title, rule count, sudden drops) before use, and a bad update keeps the previous copy.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ l: FilterListSource) -> some View {
        let on = shield.config.enabledLists.contains(l.id)
        return VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(get: { on }, set: { v in
                shield.update { c in
                    if v { if !c.enabledLists.contains(l.id) { c.enabledLists.append(l.id) } } else { c.enabledLists.removeAll { $0 == l.id } }
                }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.name).fontWeight(.medium)
                    Text(l.summary).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Text(layers(l)).font(.caption2).foregroundColor(.secondary)
                if let r = lists.records[l.id] {
                    Text("\(r.ruleCount.formatted()) rules · \(RelativeDateTimeFormatter().localizedString(for: r.fetchedAt, relativeTo: Date()))")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if let u = URL(string: l.licenceURL) { Link("Licence: \(l.licence)", destination: u).font(.caption2) }
                if let u = URL(string: l.homepage) { Link("Homepage", destination: u).font(.caption2) }
            }
            if let e = lists.errors[l.id] { Text(e).font(.caption2).foregroundColor(.orange) }
        }
    }

    private func layers(_ l: FilterListSource) -> String {
        [l.dns ? "System-wide" : nil, l.browser ? "Browsers" : nil].compactMap { $0 }.joined(separator: " + ")
    }
}

// MARK: - My rules (custom rules + allowlist)

struct ShieldRulesView: View {
    @ObservedObject private var shield = ShieldController.shared
    @State private var draft = ""
    @State private var loaded = false
    @State private var newAllow = ""

    var body: some View {
        Form {
            Section("Allowlist") {
                ForEach(shield.config.allowlist, id: \.self) { d in
                    HStack {
                        Text(d)
                        Spacer()
                        Button("Remove") { shield.removeAllowed(d) }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Domain or URL to always allow", text: $newAllow).textFieldStyle(.roundedBorder)
                        .onSubmit(addAllow)
                    Button("Allow", action: addAllow).disabled(DomainName.host(fromURLOrHost: newAllow) == nil)
                }
                Text("Allowed domains (and their subdomains) are never blocked by any list, in every app.").font(.caption).foregroundColor(.secondary)
            }
            Section("Custom rules") {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                let problems = UserRules(customRules: draft).problems()
                if !problems.isEmpty {
                    ForEach(problems.prefix(5), id: \.line) { p in
                        Text("Line \(p.line): \(p.message)").font(.caption).foregroundColor(.orange)
                    }
                }
                HStack {
                    Button("Save Rules") { shield.update { $0.customRules = draft } }
                        .disabled(draft == shield.config.customRules)
                    Button("Revert") { draft = shield.config.customRules }.disabled(draft == shield.config.customRules)
                }
                Text("""
                One rule per line, in Adblock or hosts syntax:
                ||ads.example.com^        block a domain and its subdomains
                @@||cdn.example.com^      never block this one
                0.0.0.0 tracker.example   hosts-file style (that exact name)
                ||ad*.example.net^        wildcards
                /^track[0-9]+\\.site\\.com$/   regular expression (hostname)
                ||example.org^$important  wins over list exceptions
                example.com##.ad-banner   hide page elements (browser extensions)
                ! comment
                """)
                .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if !loaded { draft = shield.config.customRules; loaded = true } }
    }

    private func addAllow() {
        guard DomainName.host(fromURLOrHost: newAllow) != nil else { return }
        shield.allow(site: newAllow)
        newAllow = ""
    }
}

// MARK: - Browsers

struct ShieldBrowsersView: View {
    @ObservedObject private var shield = ShieldController.shared

    var body: some View {
        Form {
            Section {
                Text("System-wide blocking works by domain name, so it can't remove ads served from the same domain as the content, such as YouTube's video ads or sponsored posts in a feed. The browser extensions handle those, best-effort: they hide ad elements on pages, run small scripts (\"scriptlets\") that strip ad data before the page uses it, and block ad requests by URL. Sites like YouTube change often, so in-page blocking can break until the lists catch up.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Safari") {
                Text("Turn on \"Swoop Shield 1–6\" (content blockers) and \"Swoop Shield Page Cleaner\" in Safari › Settings › Extensions.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Safari Extensions Settings") {
                        SFSafariApplication.showPreferencesForExtension(withIdentifier: "com.swoopkey.swoop.safari.webext") { _ in }
                    }
                    Button("Reload Safari Rules") { shield.reloadSafari() }
                }
                if ShieldController.groupDir == nil {
                    Text("This build has no App Group, so Safari can't read Swoop's rules (Developer ID builds only).").font(.caption).foregroundColor(.orange)
                }
            }
            Section("Chrome, Arc, Brave, Edge, Vivaldi, Opera") {
                Text("1. Open chrome://extensions (edge://extensions, brave://extensions…)\n2. Turn on Developer mode\n3. Click \"Load unpacked\" and choose the folder Swoop shows you.\nAfter a list update, click Reload on the extension to pick up the new rules.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show Chromium Extension Folder") { shield.lists.revealBrowserExtension("chromium") }
            }
            Section("Firefox") {
                Text("Open about:debugging › This Firefox › Load Temporary Add-on… and choose manifest.json in the folder Swoop shows you. Firefox removes temporary add-ons when it quits; a permanent install needs the add-on signed by Mozilla (not published yet).")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show Firefox Extension Folder") { shield.lists.revealBrowserExtension("firefox") }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

struct ShieldAdvancedView: View {
    @ObservedObject private var shield = ShieldController.shared

    private var upstreamChoice: Binding<String> {
        Binding(get: {
            switch shield.config.upstream {
            case .system: return "system"
            case .doh(let url, _): return Upstream.presets.first { if case .doh(let u, _) = $0.upstream { return u == url }; return false }?.title ?? "system"
            case .servers: return "system"
            }
        }, set: { v in
            shield.update { c in c.upstream = Upstream.presets.first { $0.title == v }?.upstream ?? .system }
        })
    }

    var body: some View {
        Form {
            Section("Blocking") {
                Picker("Answer blocked lookups with", selection: Binding(get: { shield.config.blockResponse }, set: { v in shield.update { $0.blockResponse = v } })) {
                    ForEach(BlockResponse.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Uncloak CNAME trackers", isOn: Binding(get: { shield.config.cnameUncloaking }, set: { v in shield.update { $0.cnameUncloaking = v } }))
                Toggle("Also block well-known cloaking networks not in my lists", isOn: Binding(get: { shield.config.builtInCloakTrackers }, set: { v in shield.update { $0.builtInCloakTrackers = v } }))
                    .disabled(!shield.config.cnameUncloaking)
                Text("Some sites disguise trackers as their own subdomains (metrics.shop.com → shop.tracker.net). Shield checks every name in the answer's CNAME chain against your lists.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Encrypted DNS") {
                Picker("Apps using their own DNS", selection: Binding(get: { shield.config.encryptedDNS }, set: { v in shield.update { $0.encryptedDNS = v } })) {
                    ForEach(EncryptedDNSMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Ask iCloud Private Relay to step aside on this Mac", isOn: Binding(get: { shield.config.blockPrivateRelay }, set: { v in shield.update { $0.blockPrivateRelay = v } }))
                Text("Firefox, Chrome and some apps can send DNS over HTTPS straight to Google or Cloudflare, skipping Shield. Shield tells Firefox to switch that off, makes public DoH servers unreachable so browsers fall back to the system resolver, and (system extension) blocks DNS-over-TLS/QUIC. Private Relay: macOS will show a notice that Private Relay is off for this network.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Upstream DNS", selection: upstreamChoice) {
                    Text("Same as macOS (your network's DNS)").tag("system")
                    ForEach(Upstream.presets, id: \.title) { Text($0.title).tag($0.title) }
                }
            }
            Section("Menu bar") {
                Toggle("Show blocked-today counter in the menu bar", isOn: $shield.menuBarCounter)
            }
            Section("Maintenance") {
                HStack {
                    Button("Reset Statistics") { shield.resetStats() }
                    Button("Clear Query Log") { shield.clearLog() }
                }
                if shield.systemExtensionAvailable {
                    Button("Uninstall System Extension…") {
                        if Actions.confirm("Uninstall the Shield system extension?", "System-wide filtering stops until you turn Shield on again.", ok: "Uninstall", destructive: true) {
                            shield.uninstallSystemExtension()
                        }
                    }
                }
                Button("Reveal Shield Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([ShieldController.dir]) }
            }
        }
        .formStyle(.grouped)
    }
}
