// SPDX-License-Identifier: MIT
//
// One place that decides whether a feature can run and, when it can't, says so calmly
// with a Set Up button that opens the exact System Settings pane. Nothing fails silently,
// and nothing tries to get around macOS's privacy controls.
import AppKit
import SwiftUI
import SwoopCore

enum PermissionGate {
    /// True when the feature can run now. Otherwise shows a calm note (inline in the launcher
    /// when it's open, or a small panel) and returns false.
    @discardableResult
    static func check(_ feature: PermissionFeature) -> Bool {
        guard !Permissions.isAvailable(feature) else { return true }
        present(feature)
        return false
    }

    static func present(_ feature: PermissionFeature, state: PermissionState = Permissions.state) {
        DispatchQueue.main.async {
            if LauncherController.shared.isVisible {
                LauncherController.shared.model.permissionNote = feature
            } else {
                PermissionNoticePanel.show(feature, state: state)
            }
        }
    }
}

/// A small floating card: what's missing, what Swoop does meanwhile, Set Up / Not Now.
enum PermissionNoticePanel {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    static func show(_ feature: PermissionFeature, state: PermissionState) {
        close()
        let view = PermissionNoticeView(feature: feature, state: state,
                                        setUp: { close(); if let p = state.missing(for: feature) { Permissions.setUp(p) } },
                                        dismiss: { close() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: max(110, size.height))),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - p.frame.height - 16))
        }
        p.orderFrontRegardless()
        panel = p
        let work = DispatchWorkItem { close() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    static func close() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct PermissionNoticeView: View {
    let feature: PermissionFeature
    let state: PermissionState
    let setUp: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 22)).foregroundColor(.secondary)
                Text(state.note(for: feature) ?? "")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Not Now", action: dismiss)
                Button("Set Up…", action: setUp).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// The inline note the launcher shows above its footer.
struct PermissionNoteBar: View {
    let feature: PermissionFeature
    let state: PermissionState
    let setUp: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundColor(.secondary)
            Text(state.note(for: feature) ?? "").font(.caption).foregroundColor(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Set Up…", action: setUp).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }
}

/// One permission on the permissions screen (onboarding and Settings).
struct PrivacyPermissionRow: View {
    let permission: PrivacyPermission
    let granted: Bool
    let isAdmin: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : permission.symbol)
                .font(.system(size: 18)).foregroundColor(granted ? .green : .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(permission.title).font(.headline)
                    Text(granted ? "On" : "Optional").font(.caption).foregroundColor(.secondary)
                }
                Text(permission.purpose).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Used by: " + permission.features.map(\.title).joined(separator: ", "))
                    .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text("Granted").font(.caption).foregroundColor(.secondary)
            } else {
                Button("Set Up…") { Permissions.setUp(permission) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// The whole permissions screen body, shared by onboarding and Settings.
struct PrivacyPermissionsList: View {
    @State private var state = Permissions.state
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    var onChange: ((PermissionState) -> Void)?

    init(onChange: ((PermissionState) -> Void)? = nil) { self.onChange = onChange }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PrivacyPermission.allCases, id: \.self) { p in
                PrivacyPermissionRow(permission: p, granted: state.isGranted(p), isAdmin: state.isAdmin)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: state.isAdmin ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark")
                    .foregroundColor(.secondary)
                Text(state.isAdmin
                     ? "You're an administrator on this Mac. " + PermissionCopy.adminAccount
                     : PermissionCopy.standardAccount + " If that isn't you, ask whoever manages this Mac, or skip these for now.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(PermissionCopy.howToGrant + " " + PermissionCopy.alwaysWorks)
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(timer) { _ in
            let s = Permissions.state
            if s != state { state = s; onChange?(s) }
        }
    }
}

/// A calm inline note that appears only while the feature's permission is missing, with a
/// Set Up button for the exact pane. Disappears by itself once it's granted.
struct PermissionInlineNote: View {
    let feature: PermissionFeature
    @State private var available: Bool
    @State private var state: PermissionState?
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(feature: PermissionFeature) {
        self.feature = feature
        let ok = Permissions.isAvailable(feature)
        _available = State(initialValue: ok)
        _state = State(initialValue: ok ? nil : Permissions.state)
    }

    var body: some View {
        Group {
            if !available, let s = state {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").foregroundColor(.secondary)
                    Text(s.note(for: feature) ?? "").font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Set Up…") { if let p = s.missing(for: feature) { Permissions.setUp(p) } }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
        .onReceive(timer) { _ in
            let ok = Permissions.isAvailable(feature)
            if ok != available { available = ok; state = ok ? nil : Permissions.state }
        }
    }
}
