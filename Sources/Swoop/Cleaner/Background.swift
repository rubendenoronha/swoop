// SPDX-License-Identifier: MIT
import AppKit
import Darwin
import SwoopCore

// MARK: - Space Lens scanner

enum SpaceScanner {
    /// Builds a size tree under `root`, keeping nodes `depth` levels deep (deeper folders
    /// are sized but not expanded; opening one rescans from there).
    static func scan(_ root: URL, depth: Int = 3, cancel: CancelToken, progress: @escaping (Int) -> Void) -> DiskNode {
        var counter = 0
        return node(root, depth: depth, cancel: cancel, counter: &counter, progress: progress)
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                                 .fileAllocatedSizeKey, .isPackageKey]

    private static func node(_ url: URL, depth: Int, cancel: CancelToken, counter: inout Int,
                             progress: @escaping (Int) -> Void) -> DiskNode {
        let v = try? url.resourceValues(forKeys: Set(keys))
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        if v?.isSymbolicLink == true { return DiskNode(name: name, path: url.path, size: 0, isDirectory: false) }
        guard v?.isDirectory == true else {
            return DiskNode(name: name, path: url.path, size: Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0),
                            isDirectory: false)
        }
        if depth <= 0 || v?.isPackage == true || cancel.cancelled {
            counter += 1
            return DiskNode(name: name, path: url.path, size: Sizer.size(of: url), isDirectory: true)
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        var nodes: [DiskNode] = []
        for c in children {
            if cancel.cancelled { break }
            // Don't follow into other volumes or system internals from "/".
            if url.path == "/" && ["Volumes", "System", "dev", "private", "cores"].contains(c.lastPathComponent) { continue }
            nodes.append(node(c, depth: depth - 1, cancel: cancel, counter: &counter, progress: progress))
            counter += 1
            if counter % 200 == 0 { let n = counter; DispatchQueue.main.async { progress(n) } }
        }
        let total = nodes.reduce(Int64(0)) { $0 + $1.size }
        return DiskNode(name: name, path: url.path, size: total, isDirectory: true, children: nodes)
    }
}

// MARK: - Scheduled clean-ups

final class CleanupScheduler {
    static let shared = CleanupScheduler()
    private var timer: Timer?

    func start() {
        reschedule()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkDue()
        }
    }

    func reschedule() {
        timer?.invalidate()
        guard Prefs.shared.schedule.frequency != .off else { return }
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.checkDue() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkDue() }
    }

    func checkDue() {
        let s = Prefs.shared.schedule
        guard s.isDue(now: Date()) else { return }
        runNow(automatic: true)
    }

    /// Scheduled clean-ups only use the categories the user picked, never language files,
    /// and always go to the Trash (restorable) even when manual deletes are permanent.
    func runNow(automatic: Bool) {
        let s = Prefs.shared.schedule
        let cats = Set(s.categories)
        let rules = JunkScanner.enabledRules.filter { cats.contains($0.category.rawValue) && $0.category != .languageFiles && !$0.alwaysPermanent }
        DispatchQueue.global(qos: .utility).async {
            let items = JunkScanner.scan(rules: rules)
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            DispatchQueue.main.async {
                var sched = Prefs.shared.schedule
                sched.lastRun = Date()
                Prefs.shared.schedule = sched
                guard total >= s.onlyIfOverBytes || !automatic else { return }
                // Emptying the Trash is permanent, so it never runs unattended.
                let trashable = items.filter { $0.group != JunkCategory.trash.title }
                let reasons = Dictionary(items.map { ($0.url, $0.note) }, uniquingKeysWith: { a, _ in a })
                let saved = Prefs.shared.deletePermanently
                Prefs.shared.deletePermanently = false
                let r = FileRemover.shared.remove(trashable.map { $0.url }, module: "Scheduled Clean-up", reasons: reasons,
                                                  defaultReason: "Scheduled clean-up")
                Prefs.shared.deletePermanently = saved
                if s.notify { Notifier.show("Swoop cleaned \(Bytes.format(r.bytes))", body: "Scheduled clean-up · restorable from Swoop") }
            }
        }
    }
}

// MARK: - System stats (menu bar monitor)

struct SystemStats {
    var cpu: Double = 0              // 0…1
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memoryPressure: Double = 0   // 0…1, wired+compressed share
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
}

final class StatsReader {
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    func read() -> SystemStats {
        var s = SystemStats()
        s.cpu = cpuUsage()
        let (used, pressure) = memory()
        s.memoryUsed = used
        s.memoryPressure = pressure
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
        return s
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = (user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1), idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
        defer { lastTicks = t }
        guard let l = lastTicks else { return 0 }
        let busy = Double((t.user &- l.user) &+ (t.system &- l.system) &+ (t.nice &- l.nice))
        let all = busy + Double(t.idle &- l.idle)
        return all > 0 ? busy / all : 0
    }

    private func memory() -> (UInt64, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        // "Memory Used" as Activity Monitor shows it: app memory + wired + compressed.
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let used = (app &+ wired &+ compressed) &* page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let pressure = total > 0 ? Double((wired &+ compressed) &* page) / total : 0
        return (used, min(1, pressure))
    }
}

// MARK: - Permissions

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Input Monitoring (listen-only keyboard events). Accessibility implies it.
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// Full Disk Access can't be queried directly; reading a TCC-protected file is the
    /// standard test.
    static var fullDiskAccess: Bool {
        let probes = [NSHomeDirectory() + "/Library/Safari/CloudTabs.db", NSHomeDirectory() + "/Library/Safari/History.db",
                      "/Library/Application Support/com.apple.TCC/TCC.db"]
        for p in probes where FileManager.default.fileExists(atPath: p) {
            if let h = FileHandle(forReadingAtPath: p) { try? h.close(); return true }
        }
        return false
    }

    static func isGranted(_ p: PrivacyPermission) -> Bool {
        switch p {
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .fullDiskAccess: return fullDiskAccess
        }
    }

    /// Cheap check for one feature (only probes the permissions it needs).
    static func isAvailable(_ f: PermissionFeature) -> Bool { f.permissions.contains(where: isGranted) }

    /// Whether the logged-in user is in the admin group. Standard users can still turn the
    /// switches on, but macOS asks an administrator to approve each one.
    static var isAdmin: Bool {
        guard let pw = getpwuid(getuid()) else { return false }
        let adminGID = getgrnam("admin")?.pointee.gr_gid ?? 80
        if pw.pointee.pw_gid == adminGID { return true }
        var count: Int32 = 32
        var groups = [Int32](repeating: 0, count: Int(count))
        while getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count) == -1 {
            count = max(count * 2, Int32(groups.count * 2))
            if count > 4096 { break }
            groups = [Int32](repeating: 0, count: Int(count))
        }
        return groups.prefix(Int(max(0, min(count, Int32(groups.count))))).contains(Int32(bitPattern: adminGID))
    }

    /// Everything granted right now, plus whether this is an admin account.
    static var state: PermissionState {
        PermissionState(granted: Set(PrivacyPermission.allCases.filter(isGranted)), isAdmin: isAdmin)
    }

    /// Asks macOS to list Swoop under the permission (where it can) and opens the exact pane.
    /// Never touches TCC itself.
    static func setUp(_ p: PrivacyPermission) {
        switch p {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .fullDiskAccess:
            break
        }
        Actions.openURLString(p.settingsURL)
    }

    static func requestAccessibility(reason: String? = nil) {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts), let r = reason { Notifier.show("Accessibility needed", body: r) }
    }

    static func openAccessibilitySettings() { Actions.openURLString(PrivacyPermission.accessibility.settingsURL) }

    static func openFullDiskAccessSettings() { Actions.openURLString(PrivacyPermission.fullDiskAccess.settingsURL) }

    static func openKeyboardShortcuts() {
        Actions.openURLString("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }
}
