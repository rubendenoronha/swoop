// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import SwoopCore

/// "Click to record" hotkey field. Any modifier+key combo (⌘Space included), or a
/// double-tapped modifier from the menu. Shows conflicts with Swoop's other bindings,
/// macOS's own shortcuts, and combos another app already registered.
struct HotkeyRecorder: View {
    let actionID: String
    let title: String
    var allowsClear = true

    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var center = HotKeyCenter.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pending: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Text(recording ? "Type a shortcut…" : (prefs.trigger(for: actionID)?.display ?? "Record Shortcut"))
                        .frame(minWidth: 120)
                        .foregroundColor(recording ? .accentColor : .primary)
                }
                .help("Click, then press the keys. Esc cancels, ⌫ clears.")
                Menu {
                    ForEach(HotkeyTrigger.Modifier.allCases, id: \.self) { m in
                        Button("Double-tap \(m.symbol)\(m.symbol)") { assign(.doubleTap(m)) }
                    }
                } label: { Image(systemName: "hand.tap") }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
                .help("Use a double-tapped modifier key instead")
                if allowsClear && prefs.trigger(for: actionID) != nil && actionID != HotKeyCenter.launcherID {
                    Button { prefs.setTrigger(nil, for: actionID); pending = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain).help("Remove shortcut")
                }
            }
            ForEach(messages, id: \.self) { m in
                Label(m, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
    }

    private var messages: [String] {
        var out = pending
        if let f = center.failures[actionID], !out.contains(f) { out.append(f) }
        return out
    }

    private func toggleRecording() { recording ? stop() : start() }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording {
            recording = false
            HotKeyCenter.shared.resume()
        }
    }

    private func handle(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let noMods = !(f.contains(.command) || f.contains(.option) || f.contains(.control) || f.contains(.shift))
        if e.keyCode == 53 && noMods { stop(); return }                         // Esc
        if (e.keyCode == 51 || e.keyCode == 117) && noMods && allowsClear {     // ⌫ clears
            if actionID != HotKeyCenter.launcherID { prefs.setTrigger(nil, for: actionID) }
            pending = []
            stop()
            return
        }
        guard let key = KeyCodes.name(forCode: UInt32(e.keyCode)) else { NSSound.beep(); return }
        let s = Shortcut(command: f.contains(.command), option: f.contains(.option), control: f.contains(.control),
                         shift: f.contains(.shift), key: key)
        guard Shortcut.parse(s.text) != nil else {
            pending = ["Add a modifier (⌘ ⌥ ⌃ ⇧) — a plain key can't be a global shortcut."]
            NSSound.beep()
            return
        }
        stop()
        assign(.combo(s))
    }

    private func assign(_ t: HotkeyTrigger) {
        var notes = HotkeyConflicts.check(t, for: actionID, in: HotkeyBindingList.current()).map { $0.message }
        if case .combo(let s) = t, let sys = SystemHotkeys.conflict(for: s), !notes.contains(sys) { notes.append(sys) }
        if case .doubleTap = t, !AXIsProcessTrusted() {
            notes.append("Double-tap shortcuts need Accessibility permission to work in other apps.")
        }
        pending = notes
        prefs.setTrigger(t, for: actionID)
    }
}

enum HotkeyBindingList {
    static func current() -> [HotkeyBinding] {
        var out = [HotkeyBinding(id: HotKeyCenter.launcherID, title: "Open Swoop",
                                 trigger: Prefs.shared.trigger(for: HotKeyCenter.launcherID))]
        for c in CommandCatalog.shared.bindable {
            out.append(HotkeyBinding(id: c.id, title: c.title, trigger: Prefs.shared.trigger(for: c.id)))
        }
        return out
    }
}
