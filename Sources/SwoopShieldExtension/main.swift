// SPDX-License-Identifier: MIT
//
// Swoop Shield system extension (com.swoopkey.swoop.shield). Hosts two NetworkExtension
// providers in one process:
//   • DNSProxyProvider    every DNS lookup on the Mac (all apps and browsers) is decided by
//                         ShieldCore: blocked names are answered locally, the rest are
//                         forwarded and their CNAME chains checked for cloaked trackers.
//   • FilterDataProvider  drops DNS-over-HTTPS/TLS/QUIC bypass flows and connections to
//                         blocked hostnames that apps open by name.
// Swoop.app talks to it over XPC (ShieldXPCProtocol). Nothing leaves the Mac.
import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
ShieldExtension.shared.start()
dispatchMain()
