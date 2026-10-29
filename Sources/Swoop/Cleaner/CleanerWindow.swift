// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import SwoopCore

enum CleanerModule: String, CaseIterable, Identifiable {
    case smartScan, junk, spaceLens, largeFiles, duplicates, uninstaller, loginItems, security, updates,
         maintenance, privacy, cloud, battery, restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: return "Smart Scan"
        case .junk: return "System Junk"
        case .spaceLens: return "Space Lens"
        case .largeFiles: return "Large & Old Files"
        case .duplicates: return "Duplicates"
        case .uninstaller: return "Uninstaller"
        case .loginItems: return "Login Items"
        case .security: return "Security Check"
        case .updates: return "App Updates"
        case .maintenance: return "Maintenance"
        case .privacy: return "Privacy"
        case .cloud: return "Cloud Storage"
        case .battery: return "Battery Health"
        case .restore: return "Restore"
        }
    }

    var symbol: String {
        switch self {
        case .smartScan: return "sparkles"
        case .junk: return "trash.circle"
        case .spaceLens: return "square.grid.3x3.square"
        case .largeFiles: return "doc.zipper"
        case .duplicates: return "doc.on.doc"
        case .uninstaller: return "xmark.bin"
        case .loginItems: return "power.circle"
        case .security: return "shield.lefthalf.filled"
        case .updates: return "arrow.down.app"
        case .maintenance: return "wrench.and.screwdriver"
        case .privacy: return "hand.raised"
        case .cloud: return "icloud"
        case .battery: return "battery.75"
        case .restore: return "arrow.uturn.backward.circle"
        }
    }

    var section: String {
        switch self {
        case .smartScan: return ""
        case .junk, .spaceLens, .largeFiles, .duplicates, .cloud: return "Space"
        case .uninstaller, .updates, .loginItems: return "Apps"
        case .security, .privacy: return "Protection"
        case .maintenance, .battery, .restore: return "Health"
        }
    }
}

final class CleanerState: ObservableObject {
    @Published var module: CleanerModule = .smartScan
    @Published var autoStartToken = 0
    var autoStartModule: CleanerModule?
    @Published var pendingAppPath: String?
}

enum CleanerWindow {
    static let state = CleanerState()
    private static var window: NSWindow?

    static func show(_ m: CleanerModule, autoStart: Bool = false, appPath: String? = nil) {
        LauncherController.shared.hide(restoreFocus: false)
        state.module = m
        if let p = appPath { state.pendingAppPath = p }
        if autoStart { state.autoStartModule = m; state.autoStartToken += 1 }
        let w = window ?? make()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Swoop Cleaner"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 860, height: 560)
        w.contentView = NSHostingView(rootView: CleanerRoot(state: state))
        w.center()
        w.setFrameAutosaveName("SwoopCleaner")
        window = w
        return w
    }
}

struct CleanerRoot: View {
    @ObservedObject var state: CleanerState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.module }, set: { if let m = $0 { state.module = m } })) {
                ForEach(["", "Space", "Apps", "Protection", "Health"], id: \.self) { section in
                    Section(section) {
                        ForEach(CleanerModule.allCases.filter { $0.section == section }) { m in
                            Label(m.title, systemImage: m.symbol).tag(m as CleanerModule?)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.module {
        case .smartScan: SmartScanView(state: state)
        case .junk: JunkView(state: state)
        case .spaceLens: SpaceLensView()
        case .largeFiles: LargeFilesView(state: state)
        case .duplicates: DuplicatesView()
        case .uninstaller: UninstallerView(state: state)
        case .loginItems: LoginItemsView()
        case .security: SecurityView(state: state)
        case .updates: UpdatesView(state: state)
        case .maintenance: MaintenanceView()
        case .privacy: PrivacyView()
        case .cloud: CloudStorageView()
        case .battery: BatteryView()
        case .restore: RestoreView()
        }
    }
}

// MARK: - Shared pieces

struct ModuleHeader<Trailing: View>: View {
    let module: CleanerModule
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: module.symbol)
                .font(.system(size: 26, weight: .medium)).foregroundColor(.white)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [Color(red: 0.35, green: 0.3, blue: 0.95), Color(red: 0.1, green: 0.65, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 14)
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(module: CleanerModule, subtitle: String) {
        self.module = module
        self.subtitle = subtitle
        self.trailing = EmptyView()
    }
}

/// Info button that shows the "why this is safe" note.
struct WhySafe: View {
    let note: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help(note)
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why this is safe").font(.headline)
                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14).frame(width: 300)
            }
    }
}

/// Grouped, selectable list of CleanItems with per-item safety notes.
struct CleanItemList: View {
    @Binding var items: [CleanItem]
    var emptyText = "Nothing found."

    var groups: [String] {
        var seen: [String] = []
        for i in items where !seen.contains(i.group) { seen.append(i.group) }
        return seen
    }

    var body: some View {
        if items.isEmpty {
            VStack { Spacer(); Text(emptyText).foregroundColor(.secondary); Spacer() }.frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(groups, id: \.self) { g in
                    let idx = items.indices.filter { items[$0].group == g }
                    let total = idx.reduce(Int64(0)) { $0 + items[$1].size }
                    let allOn = idx.allSatisfy { items[$0].selected }
                    Section {
                        ForEach(idx, id: \.self) { i in
                            HStack(spacing: 8) {
                                Toggle("", isOn: $items[i].selected).labelsHidden().toggleStyle(.checkbox)
                                Image(nsImage: IconCache.icon(for: items[i].url.path)).resizable().frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(items[i].url.lastPathComponent).lineLimit(1)
                                    Text((items[i].url.path as NSString).abbreviatingWithTildeInPath + (items[i].detail.isEmpty ? "" : " · " + items[i].detail))
                                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(Bytes.format(items[i].size)).monospacedDigit().foregroundColor(.secondary)
                                WhySafe(note: items[i].note)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([items[i].url]) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless).help("Reveal in Finder")
                            }
                        }
                    } header: {
                        HStack {
                            Toggle(isOn: Binding(get: { allOn }, set: { v in for i in idx { items[i].selected = v } })) {
                                Text(g).font(.headline)
                            }.toggleStyle(.checkbox)
                            Spacer()
                            Text("\(idx.count) · \(Bytes.format(total))").foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct CleanBar: View {
    let items: [CleanItem]
    let buttonTitle: String
    var busy = false
    let action: () -> Void

    var selected: [CleanItem] { items.filter { $0.selected } }

    var body: some View {
        HStack {
            Text("\(selected.count) selected · \(Bytes.format(selected.reduce(Int64(0)) { $0 + $1.size }))")
                .foregroundColor(.secondary)
            Text(Prefs.shared.deletePermanently ? "Deleted permanently" : "Moved to the Trash · restorable")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            Button(buttonTitle, action: action)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(selected.isEmpty || busy)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(.bar)
    }
}

struct ScanningView: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(text).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct StartView: View {
    let text: String
    let button: String
    /// A permission-dependent part of this module, explained inline when it's missing.
    var feature: PermissionFeature? = nil
    let action: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(text).multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 460)
            Button(button, action: action).controlSize(.large).keyboardShortcut(.defaultAction)
            if let f = feature { PermissionInlineNote(feature: f).frame(maxWidth: 460) }
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

/// Removes CleanItems, permanently for things already in the Trash.
enum CleanRunner {
    static func clean(_ items: [CleanItem], module: String) -> RemovalReport? {
        let sel = items.filter { $0.selected }
        guard !sel.isEmpty else { return nil }
        let total = sel.reduce(Int64(0)) { $0 + $1.size }
        let trashItems = sel.filter { $0.group == JunkCategory.trash.title }
        let others = sel.filter { $0.group != JunkCategory.trash.title }
        let permanent = Prefs.shared.deletePermanently
        var msg = permanent ? "\(Bytes.format(total)) will be deleted permanently."
                            : "\(Bytes.format(total)) will be moved to the Trash. Undo any time in Restore."
        if !trashItems.isEmpty { msg += "\n\nItems already in the Trash are erased permanently." }
        guard Actions.confirm("Clean \(sel.count) item\(sel.count == 1 ? "" : "s")?", msg,
                              ok: permanent ? "Delete" : "Clean", destructive: permanent || !trashItems.isEmpty) else { return nil }
        let reasons = Dictionary(sel.map { ($0.url, $0.note) }, uniquingKeysWith: { a, _ in a })
        var r = FileRemover.shared.remove(others.map { $0.url }, module: module, reasons: reasons, defaultReason: module)
        if !trashItems.isEmpty {
            let t = FileRemover.shared.remove(trashItems.map { $0.url }, module: module, reasons: reasons,
                                              defaultReason: SafetyNotes.note(forRule: "trash"), forcePermanent: true)
            r.removed += t.removed; r.bytes += t.bytes; r.failures += t.failures
        }
        FileRemover.shared.summarize(r)
        return r
    }
}
