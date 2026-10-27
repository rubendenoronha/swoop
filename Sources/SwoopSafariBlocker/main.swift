// SPDX-License-Identifier: MIT
//
// Safari content-blocker extension. One binary, packaged by build-app.sh as six .appex
// bundles (com.swoopkey.swoop.safari.blocker1 … blocker6) because Safari caps the rules
// per content blocker. Each copy hands Safari the rule chunk Swoop.app wrote for it to the
// shared App Group container: Shield/safari/blocker-<n>.json.
import Foundation

@objc(ContentBlockerRequestHandler)
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let n = bundleID.reversed().prefix { $0.isNumber }.reversed()
        let group = Bundle.main.object(forInfoDictionaryKey: "SwoopAppGroup") as? String ?? ""
        let item = NSExtensionItem()
        if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            let url = base.appendingPathComponent("Shield/safari/blocker-\(String(n)).json")
            if FileManager.default.fileExists(atPath: url.path), let provider = NSItemProvider(contentsOf: url) {
                item.attachments = [provider]
                context.completeRequest(returningItems: [item], completionHandler: nil)
                return
            }
        }
        // Nothing compiled yet: a harmless single rule (Safari rejects an empty list).
        let fallback = Data(#"[{"trigger":{"url-filter":"^swoop-shield-unused:"},"action":{"type":"block"}}]"#.utf8)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("swoop-empty.json")
        try? fallback.write(to: tmp)
        item.attachments = NSItemProvider(contentsOf: tmp).map { [$0] } ?? []
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}

// An app extension's entry point is NSExtensionMain (normally set by Xcode's linker flags).
@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
