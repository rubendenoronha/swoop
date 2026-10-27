// SPDX-License-Identifier: MIT
import Foundation

/// How a user triggers something: a modifier+key combo ("opt+space", "cmd+space") or a
/// double tap of one modifier key ("⌥⌥").
public enum HotkeyTrigger: Equatable, Codable, Hashable {
    case combo(Shortcut)
    case doubleTap(Modifier)

    public enum Modifier: String, Codable, CaseIterable, Hashable {
        case command, option, control, shift
        public var symbol: String {
            switch self {
            case .command: return "⌘"
            case .option: return "⌥"
            case .control: return "⌃"
            case .shift: return "⇧"
            }
        }
    }

    public var display: String {
        switch self {
        case .combo(let s): return s.display
        case .doubleTap(let m): return m.symbol + m.symbol
        }
    }

    /// "opt+space" or "double:option".
    public var text: String {
        switch self {
        case .combo(let s): return s.text
        case .doubleTap(let m): return "double:" + m.rawValue
        }
    }

    public static func parse(_ text: String) -> HotkeyTrigger? {
        if text.hasPrefix("double:") {
            return Modifier(rawValue: String(text.dropFirst(7))).map { .doubleTap($0) }
        }
        return Shortcut.parse(text).map { .combo($0) }
    }
}

/// Every bindable action: "open Swoop", any launcher command, each window layout,
/// clipboard history, and cleaner actions. The id is stable and stored in settings.
public struct HotkeyBinding: Equatable, Codable, Identifiable {
    public var id: String          // e.g. "launcher.toggle", "window.leftHalf", "command.clipboard-history"
    public var title: String
    public var trigger: HotkeyTrigger?

    public init(id: String, title: String, trigger: HotkeyTrigger?) {
        self.id = id
        self.title = title
        self.trigger = trigger
    }
}

public struct HotkeyConflict: Equatable {
    public let trigger: HotkeyTrigger
    public let message: String
}

public enum HotkeyConflicts {
    /// macOS shortcuts a user is likely to collide with, and how to free them up.
    public static let systemShortcuts: [String: String] = [
        "cmd+space": "Spotlight uses ⌘Space. To give it to Swoop, open System Settings › Keyboard › Keyboard Shortcuts… › Spotlight and turn off \"Show Spotlight search\" (or change it), then record ⌘Space again.",
        "opt+cmd+space": "Finder search uses ⌥⌘Space (System Settings › Keyboard › Keyboard Shortcuts… › Spotlight).",
        "ctrl+space": "Input-source switching uses ⌃Space (System Settings › Keyboard › Keyboard Shortcuts… › Input Sources).",
        "ctrl+opt+space": "Next input source uses ⌃⌥Space on some Macs (Keyboard Shortcuts › Input Sources).",
        "cmd+tab": "⌘Tab is the app switcher and can't be replaced.",
        "shift+cmd+3": "Screenshot (⇧⌘3).", "shift+cmd+4": "Screenshot (⇧⌘4).", "shift+cmd+5": "Screenshot (⇧⌘5).",
        "opt+cmd+escape": "Force Quit (⌥⌘⎋).",
        "ctrl+cmd+q": "Lock Screen (⌃⌘Q).",
        "opt+cmd+d": "Show/hide the Dock (⌥⌘D).",
        "ctrl+cmd+space": "Emoji & Symbols (⌃⌘Space). Swoop has its own emoji search.",
        "cmd+q": "⌘Q quits the frontmost app.", "cmd+w": "⌘W closes windows.", "cmd+c": "⌘C is Copy.",
        "cmd+v": "⌘V is Paste.", "cmd+x": "⌘X is Cut.", "cmd+z": "⌘Z is Undo.", "cmd+h": "⌘H hides the app.",
        "cmd+m": "⌘M minimises.", "cmd+a": "⌘A is Select All.", "cmd+s": "⌘S is Save.", "cmd+n": "⌘N is New.",
        "cmd+t": "⌘T is New Tab.", "cmd+f": "⌘F is Find.", "cmd+p": "⌘P is Print.", "cmd+o": "⌘O is Open.",
        "ctrl+up": "Mission Control (⌃↑).", "ctrl+down": "App Exposé (⌃↓).",
        "ctrl+left": "Move a Space left (⌃←).", "ctrl+right": "Move a Space right (⌃→).",
    ]

    /// Conflicts for `candidate` assigned to `id`: another Swoop binding with the same
    /// trigger, or a known macOS shortcut. (A combo already taken by another app is
    /// found at registration time, when macOS refuses it.)
    public static func check(_ candidate: HotkeyTrigger, for id: String, in bindings: [HotkeyBinding]) -> [HotkeyConflict] {
        var out: [HotkeyConflict] = []
        for b in bindings where b.id != id && b.trigger == candidate {
            out.append(HotkeyConflict(trigger: candidate, message: "Already used by Swoop for \"\(b.title)\"."))
        }
        if case .combo(let s) = candidate, let note = systemShortcuts[s.text] {
            out.append(HotkeyConflict(trigger: candidate, message: note))
        }
        if case .doubleTap(let m) = candidate, m == .shift || m == .command {
            if m == .shift {
                out.append(HotkeyConflict(trigger: candidate, message: "Double-tapping ⇧ happens while typing capitals; ⌥⌥ or ⌃⌃ are safer."))
            }
        }
        return out
    }

    /// Bindings that share a trigger (for a warning badge in Settings).
    public static func duplicates(in bindings: [HotkeyBinding]) -> [HotkeyTrigger: [String]] {
        var map: [HotkeyTrigger: [String]] = [:]
        for b in bindings { if let t = b.trigger { map[t, default: []].append(b.id) } }
        return map.filter { $0.value.count > 1 }
    }
}

/// Detects a double tap of a modifier from flags-changed events: press-release-press
/// of the same lone modifier within `interval`, with no other key in between.
public struct DoubleTapDetector {
    public let modifier: HotkeyTrigger.Modifier
    public let interval: TimeInterval
    private var lastRelease: TimeInterval?
    private var isDown = false
    private var dirty = false   // another key/modifier was involved

    public init(modifier: HotkeyTrigger.Modifier, interval: TimeInterval = 0.35) {
        self.modifier = modifier
        self.interval = interval
    }

    /// `down` = the set of modifiers held after this flags-changed event.
    /// Returns true when the double tap completes.
    public mutating func flagsChanged(_ down: Set<HotkeyTrigger.Modifier>, at t: TimeInterval) -> Bool {
        let onlyOurs = down == [modifier]
        if down.isEmpty {
            if isDown && !dirty { lastRelease = t }
            if dirty { lastRelease = nil }
            isDown = false
            dirty = false
            return false
        }
        if onlyOurs && !isDown {
            isDown = true
            if let r = lastRelease, t - r <= interval {
                lastRelease = nil
                dirty = true   // don't let the 2nd release start a new sequence
                return true
            }
            return false
        }
        // Another modifier joined.
        dirty = true
        lastRelease = nil
        return false
    }

    /// Any ordinary key press cancels a pending tap.
    public mutating func keyPressed() {
        lastRelease = nil
        if isDown { dirty = true }
    }
}
