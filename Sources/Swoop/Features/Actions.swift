// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import SwoopCore

enum Actions {
    static func openURLString(_ s: String) {
        if let u = URL(string: s), u.scheme != nil {
            NSWorkspace.shared.open(u)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (s as NSString).expandingTildeInPath))
        }
    }

    static func copy(_ text: String) {
        ClipboardManager.shared.ignoreNextChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Puts `text` on the pasteboard and pastes it into the previously active app (⌘V).
    /// Without Accessibility permission it only copies, and says so.
    static func paste(_ text: String) {
        copy(text)
        pasteFrontmost()
    }

    private static var explainedPaste = false

    static func pasteFrontmost() {
        guard Permissions.isAvailable(.pasteForYou) else {
            // Without Accessibility, Swoop still copies; it explains once per launch how to
            // let it paste too.
            if !explainedPaste {
                explainedPaste = true
                PermissionGate.present(.pasteForYou)
            } else {
                Notifier.show("Copied", body: "Press ⌘V to paste.")
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
        }
    }

    static func quickLook(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Yes/No confirmation. Keeps the launcher open while the alert is up.
    @discardableResult
    static func confirm(_ title: String, _ message: String, ok: String = "Continue", destructive: Bool = false) -> Bool {
        LauncherController.shared.model.keepOpenDepth += 1
        defer { LauncherController.shared.model.keepOpenDepth -= 1 }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = destructive ? .critical : .warning
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        if destructive { a.buttons.first?.hasDestructiveAction = true }
        return a.runModal() == .alertFirstButtonReturn
    }

    static func info(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

/// Lightweight banner: a user notification would need a permission prompt and a signed
/// bundle; a small HUD window is enough for "Copied" / "Done" feedback.
enum Notifier {
    private static var window: NSPanel?

    static func show(_ title: String, body: String? = nil) {
        DispatchQueue.main.async {
            window?.orderOut(nil)
            let text = body.map { "\(title)\n\($0)" } ?? title
            let label = NSTextField(wrappingLabelWithString: text)
            label.alignment = .center
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.preferredMaxLayoutWidth = 320
            let size = label.fittingSize
            let w = min(360, max(180, size.width + 40)), h = size.height + 26
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 12
            label.frame = NSRect(x: 20, y: 13, width: w - 40, height: size.height)
            fx.addSubview(label)
            p.contentView = fx
            if let vf = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: vf.midX - w / 2, y: vf.minY + 80))
            }
            p.orderFrontRegardless()
            window = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if window === p { p.orderOut(nil); window = nil }
            }
        }
    }
}
