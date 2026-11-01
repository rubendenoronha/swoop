// SPDX-License-Identifier: MIT
import Foundation
import SwoopCore

/// Runs the anonymous daily ping (see SwoopCore/ActiveUserPing.swift for exactly what is
/// sent). Checks shortly after launch and then hourly, so a Mac that stays on for days
/// still counts once per day; the pinger itself guarantees at most one successful ping
/// per UTC day, and nothing at all while the setting is off.
final class ActiveUserPingService: PingStore {
    static let shared = ActiveUserPingService()

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private lazy var pinger = ActiveUserPinger(store: self) { request, done in
        // Ephemeral session: no cookies, no cache, no credentials stored.
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false)
            done(ok)
            session.finishTasksAndInvalidate()
        }.resume()
    }

    var pingEnabled: Bool {
        defaults.object(forKey: ActiveUserPing.enabledKey) as? Bool ?? ActiveUserPing.enabledByDefault
    }
    var lastPingDay: String? {
        get { defaults.string(forKey: ActiveUserPing.lastDayKey) }
        set { defaults.set(newValue, forKey: ActiveUserPing.lastDayKey) }
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 600
    }

    func check() { pinger.pingIfDue() }
}
