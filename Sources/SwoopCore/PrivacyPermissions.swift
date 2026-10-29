// SPDX-License-Identifier: MIT
//
// The macOS privacy permissions Swoop asks for, which features each one unlocks, and the
// calm wording Swoop shows when one is missing. Swoop never tries to get around TCC: it
// checks, explains, and opens the exact System Settings pane. On a Standard (non-admin)
// account macOS asks an administrator to approve each switch, so the copy says so.
import Foundation

public enum PrivacyPermission: String, CaseIterable, Codable, Sendable {
    case accessibility
    case inputMonitoring
    case fullDiskAccess

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    /// The anchor of the Privacy & Security pane for this permission.
    public var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .fullDiskAccess: return "Privacy_AllFiles"
        }
    }

    /// Opens System Settings straight at this permission's list.
    public var settingsURL: String { "x-apple.systempreferences:com.apple.preference.security?" + settingsAnchor }

    public var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .fullDiskAccess: return "externaldrive"
        }
    }

    /// Everything else in Swoop works without it.
    public var isOptional: Bool { true }

    /// What it lets Swoop do, in plain words.
    public var purpose: String {
        switch self {
        case .accessibility:
            return "Lets Swoop move and resize windows, paste for you from clipboard history, snippets and emoji, expand snippet keywords as you type, and notice double-tap hotkeys."
        case .inputMonitoring:
            return "Lets double-tap hotkeys like ⌥⌥ work in other apps. Not needed if Accessibility is on. Swoop only watches modifier keys and never records what you type."
        case .fullDiskAccess:
            return "Lets the cleaner and Space Lens see protected folders such as Safari's cache and history and Mail downloads. Cleaning works everywhere else without it."
        }
    }

    /// The features that need it.
    public var features: [PermissionFeature] { PermissionFeature.allCases.filter { $0.permissions.contains(self) } }
}

/// A Swoop feature that depends on a privacy permission. A feature is available when any one
/// of its permissions is granted.
public enum PermissionFeature: String, CaseIterable, Codable, Sendable {
    case windowManagement
    case pasteForYou
    case snippetExpansion
    case doubleTapHotkeys
    case protectedFolders

    public var title: String {
        switch self {
        case .windowManagement: return "Window layouts"
        case .pasteForYou: return "Paste for you"
        case .snippetExpansion: return "Snippet expansion"
        case .doubleTapHotkeys: return "Double-tap hotkeys"
        case .protectedFolders: return "Protected folders in the cleaner"
        }
    }

    var isPlural: Bool { self == .windowManagement || self == .doubleTapHotkeys || self == .protectedFolders }

    /// Any one of these is enough.
    public var permissions: [PrivacyPermission] {
        switch self {
        case .windowManagement, .pasteForYou, .snippetExpansion: return [.accessibility]
        case .doubleTapHotkeys: return [.accessibility, .inputMonitoring]
        case .protectedFolders: return [.fullDiskAccess]
        }
    }

    /// The permission to ask for when none is granted.
    public var preferredPermission: PrivacyPermission { permissions[0] }

    /// What Swoop does meanwhile.
    public var fallback: String {
        switch self {
        case .windowManagement: return "Until then, Swoop can't move windows."
        case .pasteForYou: return "Until then, Swoop copies the text and you press ⌘V."
        case .snippetExpansion: return "Until then, insert snippets from Search Snippets."
        case .doubleTapHotkeys: return "Until then, use a key combination such as ⌥Space."
        case .protectedFolders: return "Until then, Swoop skips those folders and cleans everything else."
        }
    }

    /// The feature behind a launcher command, if it needs a permission to do its job.
    public static func forCommand(id: String) -> PermissionFeature? {
        if id.hasPrefix("window.") { return .windowManagement }
        return nil
    }
}

/// A snapshot of what's granted on this Mac and whether the user can approve it themselves.
public struct PermissionState: Equatable, Sendable {
    public var granted: Set<PrivacyPermission>
    public var isAdmin: Bool

    public init(granted: Set<PrivacyPermission>, isAdmin: Bool) {
        self.granted = granted
        self.isAdmin = isAdmin
    }

    public func isGranted(_ p: PrivacyPermission) -> Bool { granted.contains(p) }

    public func isAvailable(_ f: PermissionFeature) -> Bool { f.permissions.contains { granted.contains($0) } }

    /// The permission to set up for a feature that's unavailable, or nil when it works.
    public func missing(for f: PermissionFeature) -> PrivacyPermission? { isAvailable(f) ? nil : f.preferredPermission }

    /// The inline note shown where a feature can't run yet, or nil when it can.
    public func note(for f: PermissionFeature) -> String? {
        guard let p = missing(for: f) else { return nil }
        var s = "\(f.title) \(f.isPlural ? "need" : "needs") \(p.title). \(f.fallback)"
        if !isAdmin { s += " " + PermissionCopy.standardAccount }
        return s
    }
}

public enum PermissionCopy {
    /// What a Standard (non-admin) user should expect when they flip a switch.
    public static let standardAccount =
        "This is a Standard account, so macOS will ask an administrator to type their name and password to approve it."

    public static let adminAccount =
        "macOS may ask for your password to approve it."

    public static func approvalNote(isAdmin: Bool) -> String { isAdmin ? adminAccount : standardAccount }

    /// Shown on the permissions screen: what never needs a permission.
    public static let alwaysWorks =
        "The launcher, app and file search, calculator, clipboard history, quicklinks, the cleaner's scans and Shield all work without any of these."

    public static let howToGrant =
        "Click Set Up, find Swoop in the list (or click + and choose it from Applications), and switch it on. You may need to reopen Swoop afterwards."
}
