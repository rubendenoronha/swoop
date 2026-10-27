// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import SwoopCore

/// Borderless floating panel that can become key (for typing) without a title bar.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum LauncherMode {
    case root
    case clipboard
    case snippets
    case emoji
    case files
    case quicklinks
    case cloud(CloudService)
    case argument(title: String, placeholder: String, handler: (String) -> Void)
    case output(title: String, text: String)

    var title: String? {
        switch self {
        case .root: return nil
        case .clipboard: return "Clipboard History"
        case .snippets: return "Snippets"
        case .emoji: return "Emoji & Symbols"
        case .files: return "Files"
        case .quicklinks: return "Quicklinks"
        case .cloud(let s): return s.title
        case .argument(let t, _, _): return t
        case .output(let t, _): return t
        }
    }

    var placeholder: String {
        switch self {
        case .root: return "Search apps, commands, files, or calculate…"
        case .clipboard: return "Search clipboard history…"
        case .snippets: return "Search snippets…"
        case .emoji: return "Search emoji…"
        case .files: return "Search files…"
        case .quicklinks: return "Search quicklinks…"
        case .cloud(let s): return "Search \(s.title)…"
        case .argument(_, let p, _): return p
        case .output: return "Esc to go back"
        }
    }

    var isRoot: Bool { if case .root = self { return true }; return false }
}

final class LauncherController: NSObject, NSWindowDelegate {
    static let shared = LauncherController()

    let model = LauncherModel()
    private var panel: LauncherPanel?
    private var keyMonitor: Any?
    /// The app that was frontmost before Swoop opened: window layouts, paste and
    /// "quit app" act on it.
    private(set) var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show(mode: .root) }

    func show(mode: LauncherMode, query: String = "") {
        if !isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        }
        let p = panel ?? makePanel()
        model.enter(mode, query: query)
        position(p)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        installKeyMonitor()
    }

    func hide(restoreFocus: Bool = true) {
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        removeKeyMonitor()
        model.showActions = false
        if restoreFocus, let prev = previousApp, !prev.isTerminated {
            prev.activate(options: [])
        }
    }

    private func makePanel() -> LauncherPanel {
        let p = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: LauncherView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        panel = p
        return p
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { p.center(); return }
        let size = p.frame.size
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.62 - size.height / 2)
        p.setFrameOrigin(origin)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere closes Swoop (alerts and the open panel keep it open).
        if NSApp.modalWindow == nil, model.keepOpenDepth == 0 { hide(restoreFocus: false) }
    }

    // MARK: keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, let p = self.panel, e.window === p else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// Returns true when the key was handled here (not passed to the text field).
    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 53: // Esc
            if model.showActions { model.showActions = false } else if !model.mode.isRoot { model.enter(.root, query: "") } else { hide() }
            return true
        case 126: model.move(-1); return true            // ↑
        case 125: model.move(1); return true             // ↓
        case 36, 76:                                      // Return / Enter
            if model.showActions { model.runSelectedAction() } else { model.runPrimary(secondary: cmd) }
            return true
        default: break
        }
        if cmd, let ch = e.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "k": model.showActions.toggle(); model.actionSelection = 0; return true
            case ",": hide(restoreFocus: false); SettingsWindow.show(tab: .general); return true
            case "p": if case .clipboard = model.mode { model.togglePinSelected(); return true }
            case "f": model.toggleFavouriteSelected(); return true
            case "c": if model.copySelected() { return true }
            default:
                if let n = Int(ch), n >= 1, n <= 9 { model.runIndex(n - 1); return true }
            }
        }
        if e.keyCode == 51, model.query.isEmpty, !model.mode.isRoot {   // ⌫ on empty field goes back
            model.enter(.root, query: "")
            return true
        }
        return false
    }
}
