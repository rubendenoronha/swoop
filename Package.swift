// swift-tools-version:5.9
// SPDX-License-Identifier: MIT
//
// Swoop: a free, open-source launcher + cleaner + system-wide ad blocker for macOS 13+.
//   swift build && swift test            (SwoopCore and ShieldCore build and test on Linux too)
//   ./scripts/build-app.sh               (Swoop.app + DMG, Command Line Tools only)
import PackageDescription

var targets: [Target] = [
    // Foundation-only logic: fuzzy matching, calculator, snippets, junk rules,
    // leftover matching, path safety, script metadata, window geometry.
    .target(name: "SwoopCore", path: "Sources/SwoopCore"),
    .testTarget(name: "SwoopCoreTests", dependencies: ["SwoopCore"], path: "Tests/SwoopCoreTests"),

    // Swoop Shield engine: filter-list parser, compact domain index, matcher, CNAME
    // uncloaking, encrypted-DNS policy, DNS wire format, Safari/DNR/cosmetic converters,
    // list verification and the local resolver. Foundation + POSIX only.
    .target(name: "ShieldCore", path: "Sources/ShieldCore"),
    .testTarget(name: "ShieldCoreTests", dependencies: ["ShieldCore"], path: "Tests/ShieldCoreTests"),
    // Compiles filter lists into the DNS index + browser-extension rules (CI and developers).
    .executableTarget(name: "swoop-shield-compile", dependencies: ["ShieldCore"], path: "Sources/ShieldCompileTool"),
    // The fallback local resolver daemon (127.0.0.1:53) used without the system extension.
    .executableTarget(name: "swoop-resolver", dependencies: ["ShieldCore"], path: "Sources/SwoopResolver"),
]
var products: [Product] = [
    .library(name: "SwoopCore", targets: ["SwoopCore"]),
    .library(name: "ShieldCore", targets: ["ShieldCore"]),
    .executable(name: "swoop-shield-compile", targets: ["swoop-shield-compile"]),
    .executable(name: "swoop-resolver", targets: ["swoop-resolver"]),
]
#if os(macOS)
targets.append(.executableTarget(
    name: "Swoop",
    dependencies: ["SwoopCore", "ShieldCore"],
    path: "Sources/Swoop",
    linkerSettings: [
        .linkedFramework("Carbon"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("ServiceManagement"),
        .linkedFramework("NetworkExtension"),
        .linkedFramework("SystemExtensions"),
        .linkedFramework("SafariServices"),
    ]
))
// NetworkExtension system extension (DNS proxy + content filter). build-app.sh wraps the
// binary into Swoop.app/Contents/Library/SystemExtensions/com.swoopkey.swoop.shield.systemextension.
targets.append(.executableTarget(
    name: "SwoopShieldExtension",
    dependencies: ["ShieldCore"],
    path: "Sources/SwoopShieldExtension",
    linkerSettings: [.linkedFramework("NetworkExtension")]
))
// Safari content blocker (one binary, packaged as several .appex bundles to get past
// Safari's per-extension rule limit) and the Safari Web Extension (cosmetic + scriptlets).
targets.append(.executableTarget(
    name: "SwoopSafariBlocker",
    path: "Sources/SwoopSafariBlocker"
))
targets.append(.executableTarget(
    name: "SwoopSafariWebExtension",
    path: "Sources/SwoopSafariWebExtension",
    linkerSettings: [.linkedFramework("SafariServices")]
))
products.insert(.executable(name: "Swoop", targets: ["Swoop"]), at: 0)
#endif

let package = Package(
    name: "Swoop",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets,
    swiftLanguageVersions: [.v5]
)
