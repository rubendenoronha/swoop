# Permissions

Swoop asks for three optional macOS privacy permissions. Everything else (launcher, app and
file search, calculator, clipboard history, quicklinks, the cleaner's scans, Shield) works
without any of them.

| Permission | Unlocks | Without it |
|---|---|---|
| Accessibility | Window layouts, paste for you, snippet expansion, double-tap hotkeys | Swoop copies and you press ⌘V; snippets via Search Snippets; use a key combo |
| Input Monitoring | Double-tap hotkeys (not needed if Accessibility is on) | Use a key combo such as ⌥Space |
| Full Disk Access | Protected folders in the cleaner, Privacy and Space Lens | Those folders are skipped; everything else is cleaned |

**Standard (non-admin) accounts.** Turning any of these on shows macOS's
"Privacy & Security is trying to modify your system settings" prompt, which needs an
administrator's name and password. Swoop detects whether you're an admin and says so on the
permissions screen (onboarding and Settings › Permissions) and in every inline note.

Swoop never edits TCC or tries to bypass these prompts. When a feature needs a permission
that's off, it shows a calm note with a **Set Up…** button that opens the exact pane
(`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`,
`…?Privacy_ListenEvent`, `…?Privacy_AllFiles`). The model and copy live in
`Sources/SwoopCore/PrivacyPermissions.swift` (tested on Linux); the checks and UI in
`Sources/Swoop/App/PermissionGate.swift`.
