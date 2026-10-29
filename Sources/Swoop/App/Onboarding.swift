// SPDX-License-Identifier: MIT
import AppKit
import ServiceManagement
import SwiftUI
import SwoopCore

enum Onboarding {
    private static var window: NSWindow?

    static func show() {
        let w = window ?? make()
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }

    /// Registers (or leaves unregistered) Swoop as a login item when setup finishes.
    static func applyLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("Swoop: launch at login: \(error.localizedDescription)")
        }
        if on && service.status == .requiresApproval {
            Actions.info("Open Swoop at login", "Approve Swoop in System Settings › General › Login Items.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.title = "Welcome to Swoop"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView())
        window = w
        return w
    }
}

struct OnboardingView: View {
    @State private var step = 0
    /// Launch at login is on by default; the last step lets people opt out.
    @State private var openAtLogin = true
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 10)
            Group {
                switch step {
                case 0: welcome
                case 1: hotkey
                case 2: permissions
                default: done
                }
            }
            .frame(maxWidth: 480)
            Spacer()
            HStack {
                if step > 0 && step < 3 { Button("Back") { step -= 1 } }
                Spacer()
                HStack(spacing: 6) { ForEach(0..<4) { i in Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) } }
                Spacer()
                if step < 3 {
                    Button(step == 0 ? "Get Started" : "Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using Swoop") {
                        Onboarding.applyLaunchAtLogin(openAtLogin)
                        prefs.onboardingDone = true
                        Onboarding.close()
                        LauncherController.shared.show(mode: .root)
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
        .frame(width: 620, height: 520)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
            Text("Swoop").font(.system(size: 34, weight: .bold))
            Text("A launcher and a Mac cleaner in one free, open-source app.")
                .font(.title3).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                Label("Open apps, run commands, calculate, search files and Google Drive", systemImage: "magnifyingglass")
                Label("Clipboard history, snippets, emoji and window layouts", systemImage: "doc.on.clipboard")
                Label("Clean junk, uninstall apps fully, map your disk, check for adware", systemImage: "sparkles")
                Label("Nothing is deleted without your review; everything can be restored", systemImage: "arrow.uturn.backward.circle")
            }.font(.callout).padding(.top, 6)
        }
    }

    private var hotkey: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your hotkey").font(.title.weight(.semibold))
            Text("Press it anywhere to open Swoop. Click the box and type any combination, or pick a double-tap like ⌥⌥ from the hand menu.")
                .fixedSize(horizontal: false, vertical: true)
            HotkeyRecorder(actionID: HotKeyCenter.launcherID, title: "Open Swoop", allowsClear: false).padding(.vertical, 6)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Want ⌘Space, like Spotlight?").font(.headline)
                    Text("1. Open System Settings › Keyboard › Keyboard Shortcuts… › Spotlight.\n2. Turn off \"Show Spotlight search\".\n3. Come back here and record ⌘Space.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Open Keyboard Shortcuts") { Permissions.openKeyboardShortcuts() }
                }.padding(4)
            }
            Text("You can give any command, window layout or cleaner action its own hotkey later in Settings › Hotkeys.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions").font(.title.weight(.semibold))
            Text("All optional. Each one unlocks a few features, and Swoop tells you right where it's needed if one is off.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                PrivacyPermissionsList(onChange: { _ in SnippetEngine.shared.refresh(); HotKeyCenter.shared.reload() })
            }.frame(maxHeight: 330)
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundColor(.green)
            Text("You're set").font(.title.weight(.semibold))
            Text("Press \(prefs.trigger(for: HotKeyCenter.launcherID)?.display ?? "⌥Space") to open Swoop. Try “clean junk”, “left half”, “clipboard”, or a sum like 12*7.")
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Toggle("Open Swoop at login", isOn: $openAtLogin)
                .toggleStyle(.checkbox)
                .padding(.top, 8)
            if openAtLogin && loginNeedsApproval {
                Text("Approve Swoop in System Settings › General › Login Items.").font(.caption).foregroundColor(.orange)
            }
        }
    }
}
