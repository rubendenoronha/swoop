// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import SwoopCore

/// Raycast/Rectangle-style window management through the Accessibility API: halves,
/// quarters, thirds, two-thirds, maximize, almost-maximize, center, restore, and
/// next/previous display. Each layout is a command with its own (re-bindable) hotkey.
final class WindowManager {
    static let shared = WindowManager()
    /// Frames before Swoop moved a window, for Restore (most recent first, capped).
    private var history: [(window: AXUIElement, frame: CGRect)] = []

    func apply(_ layout: WindowLayout) {
        guard AXIsProcessTrusted() else {
            Permissions.requestAccessibility(reason: "Swoop needs Accessibility permission to move and resize windows.")
            return
        }
        guard let app = targetApp(), let win = focusedWindow(pid: app.processIdentifier),
              let current = frame(of: win) else {
            Notifier.show("No window to move", body: "Click the window you want to arrange, then try again.")
            return
        }
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let primaryH = primary.frame.height
        // Visible frames in Accessibility (top-left origin) coordinates.
        let visible = screens.map { flipRect($0.visibleFrame, primaryHeight: primaryH) }
        let center = CGPoint(x: current.midX, y: current.midY)
        let idx = visible.firstIndex { $0.contains(center) }
            ?? visible.indices.max { visible[$0].intersection(current).area < visible[$1].intersection(current).area } ?? 0

        var target: CGRect
        switch layout {
        case .restore:
            guard let saved = history.first(where: { CFEqual($0.window, win) }) else {
                Notifier.show("Nothing to restore")
                return
            }
            target = saved.frame
            history.removeAll { CFEqual($0.window, win) }
            setFrame(win, target)
            return
        case .nextDisplay, .previousDisplay:
            guard visible.count > 1 else { Notifier.show("Only one display"); return }
            // Order displays left to right so "next" moves right.
            let order = visible.indices.sorted { visible[$0].minX < visible[$1].minX }
            let pos = order.firstIndex(of: idx) ?? 0
            let step = layout == .nextDisplay ? 1 : -1
            let dest = visible[order[(pos + step + order.count) % order.count]]
            // Keep the window's relative position and size on the new display.
            let src = visible[idx]
            let rx = (current.minX - src.minX) / max(1, src.width), ry = (current.minY - src.minY) / max(1, src.height)
            let w = min(current.width, dest.width), h = min(current.height, dest.height)
            target = CGRect(x: dest.minX + rx * dest.width, y: dest.minY + ry * dest.height, width: w, height: h)
            target.origin.x = min(max(dest.minX, target.minX), dest.maxX - w)
            target.origin.y = min(max(dest.minY, target.minY), dest.maxY - h)
        default:
            target = layout.frame(in: visible[idx], current: current)
        }
        remember(win, current)
        setFrame(win, target)
    }

    private func remember(_ win: AXUIElement, _ frame: CGRect) {
        // Keep the first "original" frame until restored, so repeated snaps restore to it.
        if history.contains(where: { CFEqual($0.window, win) }) { return }
        history.insert((win, frame), at: 0)
        if history.count > 50 { history.removeLast() }
    }

    private func targetApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier { return LauncherController.shared.previousApp }
        return front
    }

    func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let v = value {
            return (v as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success, let v = value {
            return (v as! AXUIElement)
        }
        return nil
    }

    func frame(of win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    func setFrame(_ win: AXUIElement, _ r: CGRect) {
        var p = r.origin
        var s = r.size
        guard let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) else { return }
        // Size, position, size: apps clamp sizes to the screen they're on, so resize again
        // after moving between displays.
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
