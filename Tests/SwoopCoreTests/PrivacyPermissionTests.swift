// SPDX-License-Identifier: MIT
import XCTest
@testable import SwoopCore

final class PrivacyPermissionTests: XCTestCase {
    func testSettingsURLsOpenExactPanes() {
        XCTAssertEqual(PrivacyPermission.accessibility.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(PrivacyPermission.inputMonitoring.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertEqual(PrivacyPermission.fullDiskAccess.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    func testEveryPermissionExplainsItselfAndUnlocksSomething() {
        for p in PrivacyPermission.allCases {
            XCTAssertFalse(p.purpose.isEmpty)
            XCTAssertFalse(p.features.isEmpty, "\(p) unlocks nothing")
        }
        for f in PermissionFeature.allCases {
            XCTAssertFalse(f.permissions.isEmpty)
            XCTAssertFalse(f.fallback.isEmpty)
        }
    }

    func testNothingGrantedOnlyBlocksPermissionFeatures() {
        let none = PermissionState(granted: [], isAdmin: true)
        for f in PermissionFeature.allCases { XCTAssertFalse(none.isAvailable(f)) }
        XCTAssertEqual(none.missing(for: .windowManagement), .accessibility)
        XCTAssertEqual(none.missing(for: .doubleTapHotkeys), .accessibility)
        XCTAssertEqual(none.missing(for: .protectedFolders), .fullDiskAccess)
        // Launcher, calculator and clipboard commands never map to a permission.
        for id in ["command.calculator", "command.clipboard-history", "command.search-files", "system.lock", "cleaner.clean-junk"] {
            XCTAssertNil(PermissionFeature.forCommand(id: id), id)
        }
        XCTAssertEqual(PermissionFeature.forCommand(id: "window.left-half"), .windowManagement)
    }

    func testInputMonitoringIsEnoughForDoubleTapButNotForPasting() {
        let s = PermissionState(granted: [.inputMonitoring], isAdmin: false)
        XCTAssertTrue(s.isAvailable(.doubleTapHotkeys))
        XCTAssertNil(s.note(for: .doubleTapHotkeys))
        XCTAssertFalse(s.isAvailable(.pasteForYou))
        XCTAssertFalse(s.isAvailable(.snippetExpansion))
    }

    func testAccessibilityCoversEverythingButProtectedFolders() {
        let s = PermissionState(granted: [.accessibility], isAdmin: true)
        for f in PermissionFeature.allCases where f != .protectedFolders { XCTAssertTrue(s.isAvailable(f), "\(f)") }
        XCTAssertFalse(s.isAvailable(.protectedFolders))
    }

    func testNotesMentionAdministratorOnlyOnStandardAccounts() {
        let standard = PermissionState(granted: [], isAdmin: false)
        let admin = PermissionState(granted: [], isAdmin: true)
        let n1 = standard.note(for: .windowManagement) ?? ""
        let n2 = admin.note(for: .windowManagement) ?? ""
        XCTAssertTrue(n1.hasPrefix("Window layouts need Accessibility."), n1)
        XCTAssertTrue(n1.contains("administrator"))
        XCTAssertFalse(n2.contains("administrator"))
        XCTAssertTrue((admin.note(for: .pasteForYou) ?? "").hasPrefix("Paste for you needs Accessibility."))
        XCTAssertTrue(PermissionCopy.approvalNote(isAdmin: false).contains("administrator"))
    }
}
