// SPDX-License-Identifier: MIT
import AppKit
import ServiceManagement
import SwiftUI
import SwoopCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, hotkeys, clipboard, snippets, quicklinks, cleaner, shield, cloud, permissions, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .hotkeys: return "Hotkeys"
        case .clipboard: return "Clipboard"
        case .snippets: return "Snippets"
        case .quicklinks: return "Quicklinks"
        case .cleaner: return "Cleaner"
        case .shield: return "Shield"
        case .cloud: return "Cloud"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .hotkeys: return "keyboard"
        case .clipboard: return "doc.on.clipboard"
        case .snippets: return "text.quote"
        case .quicklinks: return "link"
        case .cleaner: return "sparkles"
        case .shield: return "shield.lefthalf.filled"
        case .cloud: return "icloud"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

final class SettingsState: ObservableObject {
    @Published var tab: SettingsTab = .general
}

enum SettingsWindow {
    static let state = SettingsState()
    private static var window: NSWindow?

    static func show(tab: SettingsTab) {
        LauncherController.shared.hide(restoreFocus: false)
        state.tab = tab
        let w = window ?? make()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Swoop Settings"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsRoot(state: state))
        w.center()
        window = w
        return w
    }
}

struct SettingsRoot: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.tab }, set: { if let t = $0 { state.tab = t } })) {
                ForEach(SettingsTab.allCases) { t in Label(t.title, systemImage: t.symbol).tag(t as SettingsTab?) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
        } detail: {
            Group {
                switch state.tab {
                case .general: GeneralSettings()
                case .hotkeys: HotkeySettings()
                case .clipboard: ClipboardSettings()
                case .snippets: SnippetSettings()
                case .quicklinks: QuicklinkSettings()
                case .cleaner: CleanerSettings()
                case .shield: ShieldSettings()
                case .cloud: CloudSettings()
                case .permissions: PermissionSettings()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Open Swoop") {
                LabeledContent("Hotkey") { HotkeyRecorder(actionID: HotKeyCenter.launcherID, title: "Open Swoop", allowsClear: false) }
                Text("Any combination works, including ⌘Space (turn off Spotlight's shortcut first: System Settings › Keyboard › Keyboard Shortcuts… › Spotlight), or a double-tapped modifier such as ⌥⌥.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Shortcuts Settings") { Permissions.openKeyboardShortcuts() }
            }
            Section("Startup") {
                Toggle("Launch Swoop at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = error.localizedDescription }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                if let e = loginError { Text(e).font(.caption).foregroundColor(.orange) }
                if SMAppService.mainApp.status == .requiresApproval {
                    Text("Approve Swoop in System Settings › General › Login Items.").font(.caption).foregroundColor(.orange)
                }
            }
            Section("Search") {
                Picker("Web search fallback", selection: $prefs.searchEngine) {
                    Text("Google").tag("google"); Text("DuckDuckGo").tag("duckduckgo"); Text("Bing").tag("bing")
                    Text("Kagi").tag("kagi"); Text("Ecosia").tag("ecosia")
                }
                Toggle("Include files (Spotlight) in results", isOn: $prefs.fileSearchEnabled)
                Toggle("Include Google Drive files in results", isOn: $prefs.cloudSearchInLauncher)
            }
            Section("Script Commands") {
                LabeledContent("Folder") {
                    HStack {
                        Text((prefs.scriptsFolder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Button("Change…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { prefs.scriptsFolder = u.path }
                        }
                        Button("Reveal") { NSWorkspace.shared.open(URL(fileURLWithPath: prefs.scriptsFolder)) }
                    }
                }
                Text("Drop in any Raycast-compatible script command (bash, python, node, swift, AppleScript…). \(ScriptCommands.shared.scripts.count) loaded.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Reload Scripts") { ScriptCommands.shared.reload() }
            }
            Section("Menu bar") {
                Toggle("Show CPU and memory in the menu bar", isOn: $prefs.menuBarShowsStats)
                    .onChange(of: prefs.menuBarShowsStats) { _ in MenuBarMonitor.shared.refreshVisibility() }
            }
            Section {
                Button("Show Welcome Again") { Onboarding.show() }
            }
        }.formStyle(.grouped)
    }
}

// MARK: - Hotkeys

struct HotkeySettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter commands", text: $filter).textFieldStyle(.roundedBorder)
                Button("Reset Window Shortcuts") {
                    var b = prefs.bindings
                    for l in WindowLayout.allCases { b["window." + l.rawValue] = l.defaultShortcut ?? "" }
                    prefs.bindings = b
                }
                Button("Clear All") {
                    if Actions.confirm("Remove every custom hotkey?", "The Open Swoop hotkey is kept.", ok: "Clear") { prefs.bindings = [:] }
                }
            }.padding(16)
            Form {
                Section("Open Swoop") {
                    LabeledContent("Open Swoop") { HotkeyRecorder(actionID: HotKeyCenter.launcherID, title: "Open Swoop", allowsClear: false) }
                }
                ForEach(SwoopCommand.Group.allCases, id: \.rawValue) { g in
                    let cmds = CommandCatalog.shared.bindable.filter { $0.group == g && (filter.isEmpty || FuzzyMatcher.match(filter, in: $0.title) != nil) }
                    if !cmds.isEmpty {
                        Section(g.rawValue) {
                            ForEach(cmds) { c in
                                LabeledContent(c.title) { HotkeyRecorder(actionID: c.id, title: c.title) }
                            }
                        }
                    }
                }
                Section {
                    Text("Double-tap shortcuts and snippet expansion need Accessibility permission. If macOS or another app already owns a combination, Swoop tells you here.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}

// MARK: - Clipboard

struct ClipboardSettings: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section("Clipboard History") {
                Toggle("Keep clipboard history", isOn: $prefs.clipboardEnabled)
                    .onChange(of: prefs.clipboardEnabled) { on in on ? ClipboardManager.shared.start() : ClipboardManager.shared.stop() }
                Picker("Keep items for", selection: $prefs.clipboardRetentionDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("Forever").tag(0)
                }
                LabeledContent("Open history") { HotkeyRecorder(actionID: "command.clipboard-history", title: "Clipboard History") }
                LabeledContent("Stored") { Text("\(ClipboardManager.shared.count) items, on this Mac only") }
                Button("Clear History (keeps pinned)") {
                    if Actions.confirm("Clear clipboard history?", "Pinned items are kept.", ok: "Clear", destructive: true) { ClipboardManager.shared.clearAll() }
                }
            }
            Section("Privacy") {
                Text("Swoop never records copies marked as concealed or transient (how password managers mark passwords), or anything copied while 1Password, Bitwarden, LastPass, Dashlane, KeePassXC, Keychain Access or Passwords is in front. History stays in ~/Library/Application Support/Swoop and is never uploaded.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Tips") {
                Text("In Clipboard History: ↩ pastes into the app you were using, ⌘↩ copies, ⌘P pins, ⌘K shows every action.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.formStyle(.grouped)
    }
}

// MARK: - Snippets

struct SnippetSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(prefs.snippets) { s in
                        VStack(alignment: .leading) { Text(s.name); Text(s.keyword).font(.caption).foregroundColor(.secondary) }.tag(s.id as UUID?)
                    }
                }
                HStack {
                    Button { let s = Snippet(name: "New Snippet", keyword: ";new", text: ""); prefs.snippets.append(s); selection = s.id } label: { Image(systemName: "plus") }
                    Button { prefs.snippets.removeAll { $0.id == selection }; selection = nil } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }.buttonStyle(.borderless).padding(8)
            }.frame(minWidth: 200, idealWidth: 220)
            if let i = prefs.snippets.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("Name", text: $prefs.snippets[i].name)
                    TextField("Keyword", text: $prefs.snippets[i].keyword)
                    Text("Typing the keyword anywhere replaces it with the snippet. Start keywords with a symbol (like ;) so they never clash with normal words.")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $prefs.snippets[i].text).font(.system(.body, design: .monospaced)).frame(minHeight: 160)
                    Text("Placeholders: {clipboard} {date} {time} {datetime} {day} {date:yyyy-MM-dd} {uuid} {cursor}")
                        .font(.caption).foregroundColor(.secondary)
                    Toggle("Expand keywords as I type (needs Accessibility)", isOn: $prefs.snippetExpansionEnabled)
                    if prefs.snippetExpansionEnabled { PermissionInlineNote(feature: .snippetExpansion) }
                }.formStyle(.grouped).frame(minWidth: 380)
            } else {
                Text("Select or add a snippet.").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Quicklinks

struct QuicklinkSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(prefs.quicklinks) { q in
                        VStack(alignment: .leading) { Text(q.name); Text(q.keyword).font(.caption).foregroundColor(.secondary) }.tag(q.id as UUID?)
                    }
                }
                HStack {
                    Button { let q = Quicklink(name: "New Quicklink", template: "https://example.com/search?q={query}"); prefs.quicklinks.append(q); selection = q.id } label: { Image(systemName: "plus") }
                    Button { prefs.quicklinks.removeAll { $0.id == selection }; selection = nil } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }.buttonStyle(.borderless).padding(8)
            }.frame(minWidth: 200, idealWidth: 220)
            if let i = prefs.quicklinks.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("Name", text: $prefs.quicklinks[i].name)
                    TextField("Link", text: $prefs.quicklinks[i].template)
                    TextField("Keyword", text: $prefs.quicklinks[i].keyword)
                    Text("Use {query} where your search text goes. Type the keyword, a space and your text in Swoop (\"gh swoop\"), or bind the quicklink to a hotkey.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Hotkey") { HotkeyRecorder(actionID: "quicklink." + prefs.quicklinks[i].id.uuidString, title: prefs.quicklinks[i].name) }
                }.formStyle(.grouped).frame(minWidth: 380)
            } else {
                Text("Select or add a quicklink.").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Cleaner

struct CleanerSettings: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section("Removing files") {
                Picker("Removed items", selection: $prefs.deletePermanently) {
                    Text("Move to the Trash (restorable)").tag(false)
                    Text("Delete permanently").tag(true)
                }.pickerStyle(.radioGroup)
                Text("Either way, Swoop logs every removal with its reason under Restore. Protected system locations, iCloud Drive, Keychains, Mail, Messages and Photos are never touched.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("System Junk categories") {
                ForEach(JunkRules.all) { r in
                    HStack {
                        Toggle(r.title, isOn: Binding(get: { prefs.enabledJunkRules.contains(r.id) }, set: { on in
                            if on { prefs.enabledJunkRules.append(r.id) } else { prefs.enabledJunkRules.removeAll { $0 == r.id } }
                        }))
                        WhySafe(note: SafetyNotes.note(forRule: r.id))
                    }
                }
            }
            Section("Automatic clean-ups") {
                Picker("Run", selection: $prefs.schedule.frequency) {
                    Text("Never").tag(CleanupSchedule.Frequency.off)
                    Text("Daily").tag(CleanupSchedule.Frequency.daily)
                    Text("Weekly").tag(CleanupSchedule.Frequency.weekly)
                    Text("Monthly").tag(CleanupSchedule.Frequency.monthly)
                }
                Stepper("At about \(prefs.schedule.hour):00", value: $prefs.schedule.hour, in: 0...23)
                ForEach([JunkCategory.userCaches, .logs, .brokenDownloads, .browserCaches, .xcode], id: \.self) { c in
                    Toggle(c.title, isOn: Binding(get: { prefs.schedule.categories.contains(c.rawValue) }, set: { on in
                        if on { prefs.schedule.categories.append(c.rawValue) } else { prefs.schedule.categories.removeAll { $0 == c.rawValue } }
                    }))
                }
                Picker("Only when there's at least", selection: $prefs.schedule.onlyIfOverBytes) {
                    Text("Any amount").tag(Int64(0)); Text("100 MB").tag(Int64(100_000_000)); Text("500 MB").tag(Int64(500_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000)); Text("5 GB").tag(Int64(5_000_000_000))
                }
                Toggle("Tell me when a clean-up runs", isOn: $prefs.schedule.notify)
                if let last = prefs.schedule.lastRun { Text("Last run \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundColor(.secondary) }
                Text("Scheduled clean-ups always move items to the Trash (restorable), never empty the Trash, and skip language files.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Run Now") { CleanupScheduler.shared.runNow(automatic: false) }
            }
        }.formStyle(.grouped)
    }
}

// MARK: - Cloud

struct CloudSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var drive = CloudManager.shared.drive

    var body: some View {
        Form {
            Section("Google Drive") {
                if drive.isSignedIn {
                    LabeledContent("Account") { Text(drive.accountName ?? "Signed in") }
                    Button("Sign Out") { drive.signOut() }
                } else {
                    Button(drive.signingIn ? "Waiting for your browser…" : "Sign In with Google") { drive.signIn() }
                        .disabled(drive.signingIn || !drive.canSignIn)
                    Text("Opens Google in your browser. Swoop gets read-only access to search your Drive, plus access to files you upload with it. Tokens stay in your Keychain, and nothing passes through a Swoop server.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Advanced: use your own Google client") {
                    TextField("OAuth client ID", text: $prefs.googleClientID)
                    SecureField("Client secret", text: $prefs.googleClientSecret)
                    Text("Optional. Leave empty to use Swoop's. To use your own: Google Cloud Console › enable the Google Drive API › Credentials › OAuth client ID › Desktop app.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Upload hotkey") { HotkeyRecorder(actionID: "cloud.upload-drive", title: "Upload to Google Drive") }
                LabeledContent("Search hotkey") { HotkeyRecorder(actionID: "cloud.search-drive", title: "Search Google Drive") }
            }
            Section("iCloud Drive") {
                LabeledContent("Status") { Text(CloudManager.shared.icloud.isSignedIn ? "Found on this Mac" : "Not turned on") }
                Text("Search it with “Search iCloud Drive” in Swoop. It works on the local iCloud Drive folder, so no sign-in is needed.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("More services") {
                Text("Dropbox and OneDrive are planned and will plug into the same search, upload and Cloud Storage views.").font(.caption).foregroundColor(.secondary)
            }
        }.formStyle(.grouped)
    }
}

// MARK: - Permissions

struct PermissionSettings: View {
    var body: some View {
        Form {
            Section {
                PrivacyPermissionsList(onChange: { _ in SnippetEngine.shared.refresh(); HotKeyCenter.shared.reload() })
            } header: {
                Text("macOS privacy permissions")
            } footer: {
                Text("Swoop never changes these itself. Each switch lives in System Settings › Privacy & Security, and you can turn it off there at any time.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section {
                Text("System Events and Finder may ask for permission the first time you toggle dark mode, empty the Trash, or restart from Swoop. Swoop works without any of these; features that need them say so.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundColor(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { Button("Open Settings", action: action) } else { Text("Granted").foregroundColor(.secondary) }
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Swoop").font(.largeTitle.weight(.semibold))
            Text("Version \(version)").foregroundColor(.secondary)
            Text("A free, open-source launcher and Mac cleaner. No accounts, no upsells, no tracking.")
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("swoopkey.com") { Actions.openURLString("https://swoopkey.com") }.buttonStyle(.link)
            Text("© 2026 DE NORONHA LTD · MIT Licence").font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
