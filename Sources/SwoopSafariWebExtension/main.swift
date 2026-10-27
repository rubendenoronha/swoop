// SPDX-License-Identifier: MIT
//
// Safari Web Extension host (com.swoopkey.swoop.safari.webext). The extension itself is the
// shared WebExtension in Extensions/webext (cosmetic filtering, scriptlets, YouTube), copied
// into this .appex's Resources by build-app.sh. Network blocking in Safari is done by the
// content blockers; this handler only answers the extension's native messages
// (Shield on/off and paused sites, read from the App Group container).
import Foundation
import SafariServices

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let group = Bundle.main.object(forInfoDictionaryKey: "SwoopAppGroup") as? String ?? ""
        var state: [String: Any] = ["enabled": true, "pausedSites": [String]()]
        if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
           let data = try? Data(contentsOf: base.appendingPathComponent("Shield/browser-state.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            state = obj
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: state]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
