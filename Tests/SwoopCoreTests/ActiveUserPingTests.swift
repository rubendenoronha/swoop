// SPDX-License-Identifier: MIT
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwoopCore

private final class MemoryStore: PingStore {
    var pingEnabled: Bool
    var lastPingDay: String?
    init(enabled: Bool, lastDay: String? = nil) { pingEnabled = enabled; lastPingDay = lastDay }
}

final class ActiveUserPingTests: XCTestCase {
    // 2026-11-01 12:00:00 UTC
    private let noon = Date(timeIntervalSince1970: 1_793_534_400)

    func testDayKeyIsUTC() {
        XCTAssertEqual(ActiveUserPing.dayKey(for: noon), "2026-11-01")
        XCTAssertEqual(ActiveUserPing.dayKey(for: noon.addingTimeInterval(12 * 3600 - 1)), "2026-11-01")
        XCTAssertEqual(ActiveUserPing.dayKey(for: noon.addingTimeInterval(12 * 3600)), "2026-11-02")
    }

    func testDueOnlyWhenOnAndNotYetToday() {
        XCTAssertTrue(ActiveUserPing.isDue(enabled: true, lastDay: nil, now: noon))
        XCTAssertTrue(ActiveUserPing.isDue(enabled: true, lastDay: "2026-10-31", now: noon))
        XCTAssertFalse(ActiveUserPing.isDue(enabled: true, lastDay: "2026-11-01", now: noon))
        XCTAssertFalse(ActiveUserPing.isDue(enabled: false, lastDay: nil, now: noon))
        XCTAssertFalse(ActiveUserPing.isDue(enabled: false, lastDay: "2026-10-31", now: noon))
    }

    func testRequestCarriesNothingIdentifying() {
        let r = ActiveUserPing.makeRequest()
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.url?.absoluteString, "https://github.com/rubendenoronha/swoop/releases/download/heartbeat/ping.txt")
        XCTAssertNil(r.url?.query)
        XCTAssertNil(r.httpBody)
        XCTAssertFalse(r.httpShouldHandleCookies)
        XCTAssertEqual(r.allHTTPHeaderFields ?? [:], ["User-Agent": "Swoop"])
    }

    func testDefaultIsOn() {
        XCTAssertTrue(ActiveUserPing.enabledByDefault)
    }

    func testNoPingWhenOff() {
        let store = MemoryStore(enabled: false)
        var sent = 0
        let p = ActiveUserPinger(store: store, now: { self.noon }) { _, done in sent += 1; done(true) }
        XCTAssertFalse(p.pingIfDue())
        XCTAssertEqual(sent, 0)
        XCTAssertNil(store.lastPingDay)
    }

    func testAtMostOncePerDay() {
        let store = MemoryStore(enabled: true)
        var now = noon
        var sent = 0
        let p = ActiveUserPinger(store: store, now: { now }) { _, done in sent += 1; done(true) }
        XCTAssertTrue(p.pingIfDue())
        XCTAssertFalse(p.pingIfDue())
        now = now.addingTimeInterval(3 * 3600)
        XCTAssertFalse(p.pingIfDue())
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(store.lastPingDay, "2026-11-01")
        now = noon.addingTimeInterval(24 * 3600)
        XCTAssertTrue(p.pingIfDue())
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(store.lastPingDay, "2026-11-02")
    }

    func testFailureIsRetried() {
        let store = MemoryStore(enabled: true)
        var ok = false
        var sent = 0
        let p = ActiveUserPinger(store: store, now: { self.noon }) { _, done in sent += 1; done(ok) }
        XCTAssertTrue(p.pingIfDue())
        XCTAssertNil(store.lastPingDay)
        ok = true
        XCTAssertTrue(p.pingIfDue())
        XCTAssertEqual(store.lastPingDay, "2026-11-01")
        XCTAssertEqual(sent, 2)
    }

    func testNoOverlappingRequests() {
        let store = MemoryStore(enabled: true)
        var pending: ((Bool) -> Void)?
        var sent = 0
        let p = ActiveUserPinger(store: store, now: { self.noon }) { _, done in sent += 1; pending = done }
        XCTAssertTrue(p.pingIfDue())
        XCTAssertFalse(p.pingIfDue())
        pending?(true)
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(store.lastPingDay, "2026-11-01")
    }

    func testSwitchedOffMidFlightRecordsNothing() {
        let store = MemoryStore(enabled: true)
        var pending: ((Bool) -> Void)?
        let p = ActiveUserPinger(store: store, now: { self.noon }) { _, done in pending = done }
        XCTAssertTrue(p.pingIfDue())
        store.pingEnabled = false
        pending?(true)
        XCTAssertNil(store.lastPingDay)
    }
}
