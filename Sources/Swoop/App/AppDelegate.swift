// SPDX-License-Identifier: MIT
import AppKit
import ShieldCore
import SwoopCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon; Swoop lives in the menu bar
        NSApp.mainMenu = makeMainMenu()
        ScriptCommands.shared.installExampleIfEmpty()
        ScriptCommands.shared.reload()          // also registers hotkeys
        HotKeyCenter.shared.reload()
        ClipboardManager.shared.start()
        SnippetEngine.shared.refresh()
        MenuBarMonitor.shared.start()
        CleanupScheduler.shared.start()
        ShieldController.shared.start()
        DispatchQueue.global(qos: .utility).async { _ = Providers.scanApps() }
        if !Prefs.shared.onboardingDone {
            Onboarding.show()
        }
    }

    /// Opening Swoop again from Finder/Spotlight shows the launcher.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LauncherController.shared.show(mode: .root)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Accessory apps still need an Edit menu for ⌘C/⌘V/⌘A in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Swoop", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Swoop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        return main
    }

    @objc private func showAbout() { SettingsWindow.show(tab: .about) }
    @objc private func showSettings() { SettingsWindow.show(tab: .general) }
}
