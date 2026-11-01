// SPDX-License-Identifier: MIT
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The anonymous daily ping that lets us count active users.
///
/// What it is: at most once per calendar day (UTC), and only while the setting
/// "Send an anonymous daily ping" is on, Swoop makes one plain HTTPS GET for a tiny
/// public file on GitHub:
///
///     https://github.com/rubendenoronha/swoop/releases/download/heartbeat/ping.txt
///
/// GitHub counts downloads of that file, and the daily growth of the count is roughly
/// the number of Macs that used Swoop that day. The request carries no identifier, no
/// cookie, no device or usage data, no query string and no body; its User-Agent is just
/// "Swoop". Nothing about you or your Mac is stored or sent, and Swoop keeps only the
/// date of the last ping (so it doesn't ping twice in a day). Turn it off in
/// Settings › General › Privacy. See https://swoopkey.com/privacy/.
public enum ActiveUserPing {
    public static let url = URL(string: "https://github.com/rubendenoronha/swoop/releases/download/heartbeat/ping.txt")!
    public static let userAgent = "Swoop"
    public static let privacyURL = URL(string: "https://swoopkey.com/privacy/")!

    /// UserDefaults keys.
    public static let enabledKey = "anonymousDailyPing"
    public static let lastDayKey = "anonymousDailyPingLastDay"
    /// On by default; the user can switch it off at any time.
    public static let enabledByDefault = true

    /// "yyyy-MM-dd" for the UTC calendar day containing `date`.
    public static func dayKey(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Whether a ping is due: the setting is on and no ping has succeeded today.
    public static func isDue(enabled: Bool, lastDay: String?, now: Date) -> Bool {
        guard enabled else { return false }
        return lastDay != dayKey(for: now)
    }

    /// The exact request Swoop sends: a bare GET, no cookies, no extra headers.
    public static func makeRequest() -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }
}

/// Where the ping keeps its two values (UserDefaults in the app, a dictionary in tests).
public protocol PingStore: AnyObject {
    var pingEnabled: Bool { get }
    var lastPingDay: String? { get set }
}

/// Decides when to ping and records successful pings. The network call is injected, so
/// the app passes URLSession and the tests pass a fake.
public final class ActiveUserPinger {
    public typealias Send = (URLRequest, @escaping (Bool) -> Void) -> Void

    private let store: PingStore
    private let send: Send
    private let now: () -> Date
    private let lock = NSLock()
    private var inFlight = false

    public init(store: PingStore, now: @escaping () -> Date = Date.init, send: @escaping Send) {
        self.store = store; self.send = send; self.now = now
    }

    /// Sends the ping if it's on and hasn't succeeded today. A failed attempt is not
    /// recorded, so it is retried on the next check. Returns whether a request was sent.
    @discardableResult
    public func pingIfDue(completion: ((Bool) -> Void)? = nil) -> Bool {
        lock.lock()
        let today = ActiveUserPing.dayKey(for: now())
        guard !inFlight, ActiveUserPing.isDue(enabled: store.pingEnabled, lastDay: store.lastPingDay, now: now()) else {
            lock.unlock(); return false
        }
        inFlight = true
        lock.unlock()
        send(ActiveUserPing.makeRequest()) { [weak self] ok in
            guard let self = self else { return }
            self.lock.lock()
            self.inFlight = false
            // Re-check the setting: if it was switched off mid-flight, don't record anything.
            if ok && self.store.pingEnabled { self.store.lastPingDay = today }
            self.lock.unlock()
            completion?(ok)
        }
        return true
    }
}
