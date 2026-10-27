// SPDX-License-Identifier: MIT
import Foundation

/// A keyboard shortcut written as text, e.g. "opt+space", "ctrl+opt+left", "cmd+shift+v".
/// Stored as text in settings; turned into a Carbon hotkey on macOS.
public struct Shortcut: Equatable, Codable, Hashable {
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool
    public var key: String          // canonical key name ("space", "left", "a", "1", "f5")

    public init(command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false, key: String) {
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.key = key
    }

    public static func parse(_ text: String) -> Shortcut? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var s = Shortcut(key: "")
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command", "⌘": s.command = true
            case "opt", "option", "alt", "⌥": s.option = true
            case "ctrl", "control", "⌃": s.control = true
            case "shift", "⇧": s.shift = true
            default: return nil
            }
        }
        let key = KeyCodes.aliases[last] ?? last
        guard KeyCodes.codes[key] != nil else { return nil }
        s.key = key
        // A global hotkey needs at least one modifier (except function keys).
        if !(s.command || s.option || s.control || s.shift) && !key.hasPrefix("f") { return nil }
        return s
    }

    public var text: String {
        var p: [String] = []
        if control { p.append("ctrl") }
        if option { p.append("opt") }
        if shift { p.append("shift") }
        if command { p.append("cmd") }
        p.append(key)
        return p.joined(separator: "+")
    }

    /// "⌃⌥←" style label for menus and settings.
    public var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + (KeyCodes.symbols[key] ?? key.uppercased())
    }

    public var keyCode: UInt32? { KeyCodes.codes[key] }
}

/// macOS virtual key codes (kVK_* from HIToolbox/Events.h, ANSI layout).
public enum KeyCodes {
    public static let codes: [String: UInt32] = {
        var c: [String: UInt32] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
            "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
            "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B,
            "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
            "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
            ".": 0x2F, "`": 0x32,
            "return": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33, "escape": 0x35, "forwarddelete": 0x75,
            "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        ]
        let fkeys: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, k) in fkeys.enumerated() { c["f\(i + 1)"] = k }
        return c
    }()

    public static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "delete": "backspace", "del": "backspace", "spacebar": "space",
        "←": "left", "→": "right", "↑": "up", "↓": "down", "arrowleft": "left", "arrowright": "right",
        "arrowup": "up", "arrowdown": "down",
    ]

    public static let symbols: [String: String] = [
        "return": "↩", "tab": "⇥", "space": "Space", "backspace": "⌫", "escape": "⎋", "forwarddelete": "⌦",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    public static func name(forCode code: UInt32) -> String? {
        codes.first(where: { $0.value == code })?.key
    }
}
