// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import SwoopCore

/// Registers every global hotkey: the launcher's, and any the user bound to a command,
/// window layout, clipboard history or cleaner action. Combos use Carbon's
/// RegisterEventHotKey (no Accessibility permission needed); double-tap modifiers use
/// an NSEvent flags monitor (needs Accessibility to see keys typed in other apps).
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()
    static let launcherID = "launcher.toggle"

    /// Action id → why it couldn't be registered (another app owns it, invalid…).
    @Published private(set) var failures: [String: String] = [:]

    private var refs: [EventHotKeyRef] = []
    private var idByNumber: [UInt32: String] = [:]
    private var nextNumber: UInt32 = 1
    private var handlerInstalled = false
    private var suspended = false
    private var detectors: [(id: String, detector: DoubleTapDetector)] = []
    private var flagMonitors: [Any] = []

    private init() {}

    func reload() {
        unregisterAll()
        guard !suspended else { return }
        installHandler()
        var fails: [String: String] = [:]
        var ids = [HotKeyCenter.launcherID]
        ids += CommandCatalog.shared.bindable.map { $0.id }
        for id in ids {
            guard let trigger = Prefs.shared.trigger(for: id) else { continue }
            switch trigger {
            case .combo(let s):
                if let err = register(s, id: id) { fails[id] = err }
            case .doubleTap(let m):
                detectors.append((id, DoubleTapDetector(modifier: m)))
            }
        }
        if !detectors.isEmpty { startFlagMonitors() }
        failures = fails
    }

    /// While the hotkey recorder listens, nothing global fires.
    func suspend() { suspended = true; unregisterAll() }
    func resume() { suspended = false; reload() }

    private func register(_ s: Shortcut, id: String) -> String? {
        guard let code = s.keyCode else { return "Unknown key" }
        var mods: UInt32 = 0
        if s.command { mods |= UInt32(cmdKey) }
        if s.option { mods |= UInt32(optionKey) }
        if s.control { mods |= UInt32(controlKey) }
        if s.shift { mods |= UInt32(shiftKey) }
        let number = nextNumber
        nextNumber += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5357_4F50), id: number)  // 'SWOP'
        let status = RegisterEventHotKey(code, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let r = ref else {
            return status == OSStatus(-9878)   // eventHotKeyExistsErr
                ? "\(s.display) is already used by another app."
                : "macOS refused \(s.display) (error \(status))."
        }
        refs.append(r)
        idByNumber[number] = id
        return nil
    }

    private func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        idByNumber.removeAll()
        detectors.removeAll()
        for m in flagMonitors { NSEvent.removeMonitor(m) }
        flagMonitors.removeAll()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if st == noErr {
                let number = hk.id
                DispatchQueue.main.async { HotKeyCenter.shared.fire(number: number) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(number: UInt32) {
        guard let id = idByNumber[number] else { return }
        perform(id)
    }

    func perform(_ id: String) {
        if id == HotKeyCenter.launcherID {
            LauncherController.shared.toggle()
            return
        }
        CommandCatalog.shared.command(id: id)?.run()
    }

    // MARK: double tap

    private func startFlagMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handle(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            flagMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { e in handler(e); return e }) {
            flagMonitors.append(l)
        }
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            for i in detectors.indices { detectors[i].detector.keyPressed() }
            return
        }
        var down: Set<HotkeyTrigger.Modifier> = []
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command) { down.insert(.command) }
        if f.contains(.option) { down.insert(.option) }
        if f.contains(.control) { down.insert(.control) }
        if f.contains(.shift) { down.insert(.shift) }
        let t = e.timestamp
        var fired: [String] = []
        for i in detectors.indices where detectors[i].detector.flagsChanged(down, at: t) {
            fired.append(detectors[i].id)
        }
        for id in fired { DispatchQueue.main.async { HotKeyCenter.shared.perform(id) } }
    }
}

/// Shortcuts macOS itself has enabled (System Settings › Keyboard Shortcuts), read from
/// com.apple.symbolichotkeys. Used to warn before a clash (e.g. Spotlight's ⌘Space).
enum SystemHotkeys {
    struct Entry { let name: String; let shortcut: Shortcut }

    static let names: [String: String] = [
        "64": "Spotlight (Show Spotlight search)", "65": "Spotlight (Show Finder search window)",
        "60": "Input Sources (Select the previous input source)", "61": "Input Sources (Select next source)",
        "32": "Mission Control", "33": "Application windows", "36": "Show Desktop", "28": "Screenshot",
        "30": "Screenshot (selection)", "184": "Screenshot options", "79": "Move left a space", "81": "Move right a space",
        "52": "Turn Dock hiding on/off", "7": "Move focus to the menu bar", "163": "Notification Center",
        "175": "Do Not Disturb", "190": "Quick Note",
    ]

    static func enabled() -> [Entry] {
        guard let dict = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys") as? [String: Any] else { return [] }
        var out: [Entry] = []
        for (key, raw) in dict {
            guard let item = raw as? [String: Any], (item["enabled"] as? Bool) ?? ((item["enabled"] as? Int) == 1),
                  let value = item["value"] as? [String: Any], let params = value["parameters"] as? [Int],
                  params.count >= 3, let keyName = KeyCodes.name(forCode: UInt32(params[1])) else { continue }
            let m = params[2]
            let s = Shortcut(command: m & (1 << 20) != 0, option: m & (1 << 19) != 0,
                             control: m & (1 << 18) != 0, shift: m & (1 << 17) != 0, key: keyName)
            out.append(Entry(name: names[key] ?? "a macOS shortcut (#\(key))", shortcut: s))
        }
        return out
    }

    static func conflict(for s: Shortcut) -> String? {
        guard let e = enabled().first(where: { $0.shortcut == s }) else { return nil }
        if e.shortcut.text == "cmd+space" { return HotkeyConflicts.systemShortcuts["cmd+space"] }
        return "macOS uses \(s.display) for \(e.name). Turn it off in System Settings › Keyboard › Keyboard Shortcuts…"
    }
}
