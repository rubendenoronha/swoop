// SPDX-License-Identifier: MIT
import AppKit
import SwoopCore

struct RemovalReport {
    var removed = 0
    var bytes: Int64 = 0
    var failures: [(path: String, reason: String)] = []
}

/// The only place Swoop deletes anything. Every path passes PathSafety first; items go to
/// the Trash unless the user chose permanent deletion (or the item is already in the
/// Trash); every removal is logged so it can be restored from "Restore Removed Items".
final class FileRemover: ObservableObject {
    static let shared = FileRemover()
    @Published private(set) var log: RemovalLog

    private init() {
        log = JSONStore.load(RemovalLog.self, from: "removal-log.json") ?? RemovalLog()
    }

    let safety = PathSafety(home: NSHomeDirectory())

    /// Checks the path with its parent's symlinks resolved (so /tmp → /private/tmp is
    /// caught) without following a symlink that is itself the item.
    func verdict(_ url: URL) -> PathSafety.Verdict {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let real = parent.appendingPathComponent(url.lastPathComponent).path
        let v1 = safety.check(real)
        guard v1.isAllowed else { return v1 }
        return safety.check(url.standardizedFileURL.path)
    }

    func remove(_ urls: [URL], module: String, reasons: [URL: String] = [:], defaultReason: String,
                forcePermanent: Bool = false) -> RemovalReport {
        var report = RemovalReport()
        let permanent = forcePermanent || Prefs.shared.deletePermanently
        let fm = FileManager.default
        var needsFinder: [URL] = []
        for u in urls {
            if case .denied(let why) = verdict(u) {
                report.failures.append((u.path, "Protected: \(why)"))
                continue
            }
            guard fm.fileExists(atPath: u.path) || (try? u.checkResourceIsReachable()) == true || isSymlink(u) else { continue }
            let size = Sizer.size(of: u)
            let reason = reasons[u] ?? defaultReason
            do {
                if permanent {
                    try fm.removeItem(at: u)
                    record(u, trashed: nil, size: size, module: module, reason: reason)
                } else {
                    var out: NSURL?
                    try fm.trashItem(at: u, resultingItemURL: &out)
                    record(u, trashed: (out as URL?)?.path, size: size, module: module, reason: reason)
                }
                report.removed += 1
                report.bytes += size
            } catch {
                if !permanent && module == "Uninstaller" { needsFinder.append(u) }
                else { report.failures.append((u.path, error.localizedDescription)) }
            }
        }
        // App bundles installed by an installer are owned by root: let Finder move them
        // to the Trash (it asks for an administrator password).
        if !needsFinder.isEmpty {
            let sem = DispatchSemaphore(value: 0)
            let movedBox = Box<[URL: URL]>([:])
            let errorBox = Box<Error?>(nil)
            NSWorkspace.shared.recycle(needsFinder) { m, e in movedBox.value = m; errorBox.value = e; sem.signal() }
            // recycle calls back on an arbitrary queue; wait while pumping the run loop.
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            let moved = movedBox.value
            let finderError = errorBox.value
            for u in needsFinder {
                if let to = moved[u] {
                    let size = Sizer.size(of: to)
                    record(u, trashed: to.path, size: size, module: module, reason: reasons[u] ?? defaultReason)
                    report.removed += 1
                    report.bytes += size
                } else {
                    report.failures.append((u.path, finderError?.localizedDescription ?? "Finder couldn't move it"))
                }
            }
        }
        save()
        return report
    }

    private func isSymlink(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    func record(_ u: URL, trashed: String?, size: Int64, module: String, reason: String) {
        log.append(RemovalRecord(originalPath: u.path, trashedPath: trashed, size: size, module: module, reason: reason))
    }

    func save() { JSONStore.save(log, to: "removal-log.json") }

    /// Confirms (count + size + where it goes), removes, and reports the result.
    @discardableResult
    func removeWithConfirmation(_ urls: [URL], module: String, reason: String, reasons: [URL: String] = [:],
                                forcePermanent: Bool = false) -> RemovalReport? {
        guard !urls.isEmpty else { return nil }
        let total = urls.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
        let permanent = forcePermanent || Prefs.shared.deletePermanently
        let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        let msg = permanent
            ? "\(Bytes.format(total)) will be deleted permanently. This can't be undone."
            : "\(Bytes.format(total)) will be moved to the Trash. You can put everything back from Swoop › Restore Removed Items."
        guard Actions.confirm("Remove \(what)?", msg, ok: permanent ? "Delete" : "Move to Trash", destructive: permanent) else { return nil }
        let r = remove(urls, module: module, reasons: reasons, defaultReason: reason, forcePermanent: forcePermanent)
        summarize(r)
        return r
    }

    func summarize(_ r: RemovalReport) {
        if r.failures.isEmpty {
            Notifier.show("Freed \(Bytes.format(r.bytes))", body: "\(r.removed) item\(r.removed == 1 ? "" : "s") removed")
        } else {
            let list = r.failures.prefix(6).map { "• \(($0.path as NSString).lastPathComponent): \($0.reason)" }.joined(separator: "\n")
            Actions.info("Removed \(r.removed), skipped \(r.failures.count)", "Freed \(Bytes.format(r.bytes)).\n\n\(list)")
        }
    }

    /// Puts a trashed item back where it was.
    func restore(_ rec: RemovalRecord) -> String? {
        guard let from = rec.trashedPath, !rec.restored else { return "Deleted permanently; can't be restored." }
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else { return "It's no longer in the Trash." }
        guard !fm.fileExists(atPath: rec.originalPath) else { return "Something already exists at the original location." }
        do {
            try fm.createDirectory(atPath: (rec.originalPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: from, toPath: rec.originalPath)
            log.markRestored(rec.id)
            save()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum Sizer {
    /// Allocated size of a file or folder (what you get back when it's deleted).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            for case let u as URL in e {
                if let r = try? u.resourceValues(forKeys: keys), r.isDirectory != true {
                    total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }
}
