// SPDX-License-Identifier: MIT
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Window layouts

public enum WindowLayout: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case maximize, almostMaximize, center, restore, nextDisplay, previousDisplay

    public var id: String { rawValue }

    /// Default global hotkeys (Rectangle/Raycast style: Control+Option+key). Users can
    /// change or clear each one in Settings. Key names are resolved to key codes on macOS.
    public var defaultShortcut: String? {
        switch self {
        case .leftHalf: return "ctrl+opt+left"
        case .rightHalf: return "ctrl+opt+right"
        case .topHalf: return "ctrl+opt+up"
        case .bottomHalf: return "ctrl+opt+down"
        case .topLeftQuarter: return "ctrl+opt+u"
        case .topRightQuarter: return "ctrl+opt+i"
        case .bottomLeftQuarter: return "ctrl+opt+j"
        case .bottomRightQuarter: return "ctrl+opt+k"
        case .leftThird: return "ctrl+opt+d"
        case .centerThird: return "ctrl+opt+f"
        case .rightThird: return "ctrl+opt+g"
        case .leftTwoThirds: return "ctrl+opt+e"
        case .rightTwoThirds: return "ctrl+opt+t"
        case .maximize: return "ctrl+opt+return"
        case .almostMaximize: return "ctrl+opt+shift+return"
        case .center: return "ctrl+opt+c"
        case .restore: return "ctrl+opt+backspace"
        case .nextDisplay: return "ctrl+opt+cmd+right"
        case .previousDisplay: return "ctrl+opt+cmd+left"
        }
    }

    public var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .leftThird: return "First Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Last Third"
        case .leftTwoThirds: return "First Two Thirds"
        case .rightTwoThirds: return "Last Two Thirds"
        case .topLeftQuarter: return "Top Left Quarter"
        case .topRightQuarter: return "Top Right Quarter"
        case .bottomLeftQuarter: return "Bottom Left Quarter"
        case .bottomRightQuarter: return "Bottom Right Quarter"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .center: return "Center"
        case .restore: return "Restore"
        case .nextDisplay: return "Move to Next Display"
        case .previousDisplay: return "Move to Previous Display"
        }
    }

    /// Target frame inside `visible` (a screen's visible frame). Coordinates are in a
    /// top-left-origin space (the Accessibility API's), so "top" means small y.
    /// `current` is the window's current frame (used by center / nextDisplay).
    public func frame(in visible: CGRect, current: CGRect) -> CGRect {
        let x = visible.minX, y = visible.minY, w = visible.width, h = visible.height
        func r(_ fx: CGFloat, _ fy: CGFloat, _ fw: CGFloat, _ fh: CGFloat) -> CGRect {
            CGRect(x: (x + w * fx).rounded(), y: (y + h * fy).rounded(), width: (w * fw).rounded(), height: (h * fh).rounded())
        }
        switch self {
        case .leftHalf: return r(0, 0, 0.5, 1)
        case .rightHalf: return r(0.5, 0, 0.5, 1)
        case .topHalf: return r(0, 0, 1, 0.5)
        case .bottomHalf: return r(0, 0.5, 1, 0.5)
        case .leftThird: return r(0, 0, 1.0 / 3, 1)
        case .centerThird: return r(1.0 / 3, 0, 1.0 / 3, 1)
        case .rightThird: return r(2.0 / 3, 0, 1.0 / 3, 1)
        case .leftTwoThirds: return r(0, 0, 2.0 / 3, 1)
        case .rightTwoThirds: return r(1.0 / 3, 0, 2.0 / 3, 1)
        case .topLeftQuarter: return r(0, 0, 0.5, 0.5)
        case .topRightQuarter: return r(0.5, 0, 0.5, 0.5)
        case .bottomLeftQuarter: return r(0, 0.5, 0.5, 0.5)
        case .bottomRightQuarter: return r(0.5, 0.5, 0.5, 0.5)
        case .maximize: return visible
        case .almostMaximize: return r(0.05, 0.05, 0.9, 0.9)
        case .restore:
            return current   // the caller substitutes the remembered frame
        case .center, .nextDisplay, .previousDisplay:
            let cw = min(current.width, w), ch = min(current.height, h)
            return CGRect(x: (x + (w - cw) / 2).rounded(), y: (y + (h - ch) / 2).rounded(), width: cw, height: ch)
        }
    }
}

/// Flip a rect between AppKit's bottom-left-origin global space and the Accessibility
/// API's top-left-origin space. `primaryHeight` is the height of the primary screen
/// (NSScreen.screens[0]), whose bottom-left corner is the AppKit origin.
public func flipRect(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

// MARK: - System Settings panes

public struct SettingsPane: Equatable {
    public let title: String
    public let keywords: [String]
    public let urlString: String

    public init(_ title: String, _ id: String, _ keywords: [String] = []) {
        self.title = title
        self.keywords = keywords
        self.urlString = "x-apple.systempreferences:" + id
    }
}

public enum SettingsPanes {
    /// macOS 13+ System Settings deep links (extension IDs; older preference-pane IDs
    /// still resolve for the Privacy anchors).
    public static let all: [SettingsPane] = [
        SettingsPane("General", "com.apple.systempreferences.GeneralSettings"),
        SettingsPane("Wi-Fi", "com.apple.wifi-settings-extension", ["wireless", "network"]),
        SettingsPane("Bluetooth", "com.apple.BluetoothSettings"),
        SettingsPane("Network", "com.apple.Network-Settings.extension", ["ethernet", "vpn"]),
        SettingsPane("Notifications", "com.apple.Notifications-Settings.extension"),
        SettingsPane("Sound", "com.apple.Sound-Settings.extension", ["volume", "audio", "output"]),
        SettingsPane("Focus", "com.apple.Focus-Settings.extension", ["do not disturb"]),
        SettingsPane("Screen Time", "com.apple.Screen-Time-Settings.extension"),
        SettingsPane("Appearance", "com.apple.Appearance-Settings.extension", ["dark mode", "accent"]),
        SettingsPane("Accessibility", "com.apple.Accessibility-Settings.extension"),
        SettingsPane("Control Center", "com.apple.ControlCenter-Settings.extension", ["menu bar"]),
        SettingsPane("Siri & Spotlight", "com.apple.Siri-Settings.extension", ["spotlight"]),
        SettingsPane("Privacy & Security", "com.apple.settings.PrivacySecurity.extension", ["gatekeeper", "filevault"]),
        SettingsPane("Desktop & Dock", "com.apple.Desktop-Settings.extension", ["dock", "stage manager", "hot corners"]),
        SettingsPane("Displays", "com.apple.Displays-Settings.extension", ["monitor", "resolution", "night shift"]),
        SettingsPane("Wallpaper", "com.apple.Wallpaper-Settings.extension", ["background"]),
        SettingsPane("Screen Saver", "com.apple.ScreenSaver-Settings.extension"),
        SettingsPane("Battery", "com.apple.Battery-Settings.extension", ["energy", "power"]),
        SettingsPane("Lock Screen", "com.apple.Lock-Screen-Settings.extension"),
        SettingsPane("Touch ID & Password", "com.apple.Touch-ID-Settings.extension", ["fingerprint"]),
        SettingsPane("Users & Groups", "com.apple.Users-Groups-Settings.extension", ["accounts"]),
        SettingsPane("Passwords", "com.apple.Passwords-Settings.extension"),
        SettingsPane("Internet Accounts", "com.apple.Internet-Accounts-Settings.extension"),
        SettingsPane("Keyboard", "com.apple.Keyboard-Settings.extension", ["shortcuts", "input"]),
        SettingsPane("Trackpad", "com.apple.Trackpad-Settings.extension"),
        SettingsPane("Mouse", "com.apple.Mouse-Settings.extension"),
        SettingsPane("Printers & Scanners", "com.apple.Print-Scan-Settings.extension"),
        SettingsPane("Date & Time", "com.apple.Date-Time-Settings.extension", ["clock", "time zone"]),
        SettingsPane("Software Update", "com.apple.Software-Update-Settings.extension", ["upgrade"]),
        SettingsPane("Storage", "com.apple.settings.Storage", ["disk"]),
        SettingsPane("Login Items", "com.apple.LoginItems-Settings.extension", ["startup"]),
        SettingsPane("Sharing", "com.apple.Sharing-Settings.extension", ["airdrop", "screen sharing"]),
        SettingsPane("Time Machine", "com.apple.Time-Machine-Settings.extension", ["backup"]),
        SettingsPane("Language & Region", "com.apple.Localization-Settings.extension"),
        SettingsPane("Accessibility Permissions", "com.apple.preference.security?Privacy_Accessibility", ["privacy"]),
        SettingsPane("Full Disk Access", "com.apple.preference.security?Privacy_AllFiles", ["privacy"]),
    ]
}

// MARK: - Emoji

public struct EmojiItem: Equatable {
    public let emoji: String
    public let name: String
}

public enum EmojiCatalog {
    /// Every single-scalar emoji with default emoji presentation, named by its Unicode
    /// name (built at runtime from the OS's Unicode data, so no table to maintain).
    public static let all: [EmojiItem] = {
        var out: [EmojiItem] = []
        let ranges: [ClosedRange<UInt32>] = [0x2300...0x23FF, 0x2600...0x27BF, 0x2B00...0x2BFF,
                                             0x1F000...0x1FAFF]
        for range in ranges {
            for v in range {
                guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation,
                      let name = s.properties.name else { continue }
                out.append(EmojiItem(emoji: String(Character(s)), name: name.lowercased()))
            }
        }
        return out
    }()

    public static func search(_ q: String, limit: Int = 200) -> [EmojiItem] {
        let query = q.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return Array(all.prefix(limit)) }
        let scored: [(EmojiItem, Double)] = all.compactMap { e in
            if e.name.contains(query) { return (e, 100 - Double(e.name.count)) }
            if let m = FuzzyMatcher.match(query, in: e.name) { return (e, m.score) }
            return nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }
}
