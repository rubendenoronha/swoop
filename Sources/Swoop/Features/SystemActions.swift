// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import SwoopCore

enum SystemActions {
    static func lockScreen() {
        // ⌃⌘Q is the system Lock Screen shortcut; sending it needs Accessibility.
        if AXIsProcessTrusted() {
            let src = CGEventSource(stateID: .combinedSessionState)
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: false)
            d?.flags = [.maskCommand, .maskControl]
            u?.flags = [.maskCommand, .maskControl]
            d?.post(tap: .cghidEventTap)
            u?.post(tap: .cghidEventTap)
        } else {
            Shell.run("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    static func sleep() { Shell.run("/usr/bin/pmset", ["sleepnow"]) }
    static func sleepDisplays() { Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }

    static func emptyTrash() {
        guard Actions.confirm("Empty the Trash?", "Everything in the Trash is erased permanently. This can't be undone.",
                              ok: "Empty Trash", destructive: true) else { return }
        AppleScript.run("tell application \"Finder\" to empty trash")
    }

    static func toggleDarkMode() {
        AppleScript.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
    }

    static func restart() {
        guard Actions.confirm("Restart your Mac?", "Apps will be asked to quit first.", ok: "Restart") else { return }
        AppleScript.run("tell application \"System Events\" to restart")
    }

    static func shutDown() {
        guard Actions.confirm("Shut down your Mac?", "Apps will be asked to quit first.", ok: "Shut Down") else { return }
        AppleScript.run("tell application \"System Events\" to shut down")
    }

    static func logOut() {
        guard Actions.confirm("Log out?", "Apps will be asked to quit first.", ok: "Log Out") else { return }
        AppleScript.run("tell application \"System Events\" to log out")
    }

    static func ejectAll() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var ejected = 0, failed: [String] = []
        for v in vols {
            guard let r = try? v.resourceValues(forKeys: Set(keys)), r.volumeIsRootFileSystem != true else { continue }
            guard r.volumeIsEjectable == true || r.volumeIsRemovable == true || r.volumeIsInternal == false else { continue }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: v)
                ejected += 1
            } catch {
                failed.append(v.lastPathComponent)
            }
        }
        if ejected == 0 && failed.isEmpty { Notifier.show("No disks to eject") }
        else if failed.isEmpty { Notifier.show("Ejected \(ejected) disk\(ejected == 1 ? "" : "s")") }
        else { Notifier.show("Couldn't eject \(failed.joined(separator: ", "))", body: "Something is still using it.") }
    }

    static func toggleHiddenFiles() {
        let current = Shell.output("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let on = current == "1" || current == "true" || current == "yes"
        Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", on ? "false" : "true"])
        Shell.run("/usr/bin/killall", ["Finder"])
        Notifier.show(on ? "Hidden files hidden" : "Hidden files shown")
    }

    static func quitAllApps() {
        guard Actions.confirm("Quit all apps?", "Each app is asked to quit normally; apps with unsaved work will ask you first.",
                              ok: "Quit All") else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if app.bundleIdentifier == Bundle.main.bundleIdentifier || app.bundleIdentifier == "com.apple.finder" { continue }
            app.terminate()
        }
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func output(_ path: String, _ args: [String], timeout: TimeInterval = 30) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Runs a shell command with administrator rights via the standard macOS password
    /// prompt (AppleScript "with administrator privileges"). Returns (ok, output).
    static func runAsAdmin(_ command: String, prompt: String) -> (Bool, String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = prompt.replacingOccurrences(of: "\"", with: "'")
        let src = "do shell script \"\(escaped)\" with prompt \"\(p)\" with administrator privileges"
        return AppleScript.runReturning(src)
    }
}

enum AppleScript {
    @discardableResult
    static func run(_ source: String) -> Bool { runReturning(source).0 }

    static func runReturning(_ source: String) -> (Bool, String) {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (false, "") }
        let out = script.executeAndReturnError(&err)
        if let e = err {
            return (false, (e[NSAppleScript.errorMessage] as? String) ?? "AppleScript error")
        }
        return (true, out.stringValue ?? "")
    }
}
