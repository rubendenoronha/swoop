// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import Security
import SwoopCore

/// Where Swoop keeps its own data. Everything is local; nothing leaves the Mac unless the
/// user signs in to a cloud service.
enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Swoop", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static var clipboardImages: URL {
        let u = support.appendingPathComponent("ClipboardImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var defaultScripts: URL {
        let u = support.appendingPathComponent("Scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
}

enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: AppPaths.file(name)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(value) else { return }
        try? data.write(to: AppPaths.file(name), options: .atomic)
    }
}

/// Minimal Keychain wrapper for OAuth tokens (generic passwords, this user only).
enum Keychain {
    static let service = "com.swoopkey.swoop"

    static func set(_ data: Data, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// Mutable box for values filled in by @Sendable completion handlers.
final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
}
