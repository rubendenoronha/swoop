// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import SwoopCore

/// Text expansion: watches typed characters (global key monitor, needs Accessibility)
/// and replaces a snippet keyword with its text. Never runs in secure input fields
/// (password boxes turn on Secure Event Input, which also hides keys from monitors).
final class SnippetEngine {
    static let shared = SnippetEngine()
    private var monitor: Any?
    private var clickMonitor: Any?
    private var matcher = SnippetMatcher()
    private var expanding = false

    func refresh() {
        stop()
        guard Prefs.shared.snippetExpansionEnabled, AXIsProcessTrusted() else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.matcher.reset()
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        monitor = nil
        clickMonitor = nil
    }

    private func handle(_ e: NSEvent) {
        guard !expanding, !IsSecureEventInputEnabled() else { return }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command) || f.contains(.control) { matcher.reset(); return }
        // Arrows, escape, function keys: caret moved, start over.
        if [123, 124, 125, 126, 53, 115, 119, 116, 121].contains(Int(e.keyCode)) { matcher.reset(); return }
        let chars: String
        if e.keyCode == 51 { chars = "\u{7F}" } else { chars = e.characters ?? "" }
        guard let s = matcher.feed(chars, snippets: Prefs.shared.snippets) else { return }
        expand(s)
    }

    private func expand(_ s: Snippet) {
        expanding = true
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let exp = SnippetExpander.expand(s.text, clipboard: saved)
        let src = CGEventSource(stateID: .combinedSessionState)
        func tap(_ key: CGKeyCode, flags: CGEventFlags = []) {
            let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
            d?.flags = flags
            u?.flags = flags
            d?.post(tap: .cghidEventTap)
            u?.post(tap: .cghidEventTap)
        }
        // Delete the keyword, paste the text, move the caret back for {cursor}.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            for _ in 0..<s.keyword.count { tap(0x33) }
            ClipboardManager.shared.ignoreNextChange()
            pb.clearContents()
            pb.setString(exp.text, forType: .string)
            tap(0x09, flags: .maskCommand)
            if exp.cursorOffsetFromEnd > 0 {
                for _ in 0..<exp.cursorOffsetFromEnd { tap(0x7B) }
            }
            // Put the user's clipboard back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let old = saved {
                    ClipboardManager.shared.ignoreNextChange()
                    pb.clearContents()
                    pb.setString(old, forType: .string)
                }
                self.expanding = false
            }
        }
    }
}
