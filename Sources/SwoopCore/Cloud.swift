// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Provider-neutral cloud model
//
// Every cloud integration (Google Drive now; Dropbox / OneDrive later; iCloud Drive via its
// local folder) produces these types, so the launcher and the cleaner's Cloud Storage
// module don't care which service a file came from. The macOS side implements a
// `CloudProvider` protocol (sign in, search, upload, usage, large files) per service.

public enum CloudService: String, Codable, CaseIterable, Identifiable {
    case googleDrive, iCloudDrive, dropbox, oneDrive
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .iCloudDrive: return "iCloud Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        }
    }

    /// Services implemented in this version. The others are planned (same interface).
    public var isAvailable: Bool { self == .googleDrive || self == .iCloudDrive }
}

public struct CloudFile: Equatable, Identifiable {
    public let id: String
    public let service: CloudService
    public let name: String
    public let mimeType: String?
    public let size: Int64?
    public let modified: Date?
    public let webURL: String?
    public let localPath: String?

    public init(id: String, service: CloudService, name: String, mimeType: String? = nil, size: Int64? = nil,
                modified: Date? = nil, webURL: String? = nil, localPath: String? = nil) {
        self.id = id
        self.service = service
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.modified = modified
        self.webURL = webURL
        self.localPath = localPath
    }
}

public struct CloudUsage: Equatable {
    public let used: Int64
    public let limit: Int64?        // nil = unlimited / unknown
    public let inTrash: Int64?

    public init(used: Int64, limit: Int64?, inTrash: Int64? = nil) {
        self.used = used
        self.limit = limit
        self.inTrash = inTrash
    }

    public var fraction: Double? {
        guard let l = limit, l > 0 else { return nil }
        return min(1, Double(used) / Double(l))
    }
}

// MARK: - OAuth 2.0 for installed apps (loopback redirect + PKCE, RFC 7636 / RFC 8252)

public struct OAuthConfig: Equatable {
    public let authorizationEndpoint: String
    public let tokenEndpoint: String
    public let clientID: String
    public let clientSecret: String?   // Google "Desktop app" clients have a non-secret secret
    public let scopes: [String]

    public init(authorizationEndpoint: String, tokenEndpoint: String, clientID: String,
                clientSecret: String? = nil, scopes: [String]) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }

    public static func googleDrive(clientID: String, clientSecret: String?) -> OAuthConfig {
        OAuthConfig(authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
                    tokenEndpoint: "https://oauth2.googleapis.com/token",
                    clientID: clientID, clientSecret: clientSecret,
                    // drive.readonly: search + usage + large files; drive.file: upload files Swoop creates.
                    scopes: ["https://www.googleapis.com/auth/drive.readonly",
                             "https://www.googleapis.com/auth/drive.file"])
    }
}

public enum PKCE {
    /// 43–128 chars from the unreserved set. `random` is injectable for tests.
    public static func makeVerifier(length: Int = 64, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<max(43, min(128, length))).map { _ in chars[random(chars.count)] })
    }

    /// S256 challenge: BASE64URL(SHA256(verifier)) without padding.
    public static func challenge(for verifier: String) -> String {
        base64URL(SwoopSHA256.hash(Array(verifier.utf8)))
    }

    public static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthFlow {
    public static func authorizationURL(_ c: OAuthConfig, redirectURI: String, state: String, challenge: String) -> URL? {
        var comps = URLComponents(string: c.authorizationEndpoint)
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: c.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: c.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return comps?.url
    }

    /// Parses the loopback request line ("GET /?code=…&state=… HTTP/1.1"). Returns the
    /// code only when the state matches; an `error=` parameter is returned as .failure.
    public static func parseRedirect(requestLine: String, expectedState: String) -> Result<String, OAuthError> {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            return .failure(.malformedRedirect)
        }
        let items = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let e = items["error"] { return .failure(.denied(e)) }
        guard items["state"] == expectedState else { return .failure(.stateMismatch) }
        guard let code = items["code"], !code.isEmpty else { return .failure(.malformedRedirect) }
        return .success(code)
    }

    public static func form(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    public static func tokenRequestBody(_ c: OAuthConfig, code: String, verifier: String, redirectURI: String) -> Data {
        var p = [("grant_type", "authorization_code"), ("code", code), ("client_id", c.clientID),
                 ("code_verifier", verifier), ("redirect_uri", redirectURI)]
        if let s = c.clientSecret, !s.isEmpty { p.append(("client_secret", s)) }
        return form(p)
    }

    public static func refreshRequestBody(_ c: OAuthConfig, refreshToken: String) -> Data {
        var p = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", c.clientID)]
        if let s = c.clientSecret, !s.isEmpty { p.append(("client_secret", s)) }
        return form(p)
    }
}

public enum OAuthError: Error, Equatable {
    case notConfigured, malformedRedirect, stateMismatch, denied(String), tokenExchange(String), cancelled
}

public struct OAuthToken: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool { now.addingTimeInterval(60) >= expiresAt }

    /// Parses a token endpoint response. A refresh response has no refresh_token, so the
    /// previous one is kept.
    public static func parse(_ data: Data, now: Date = Date(), previousRefresh: String? = nil) -> OAuthToken? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String else { return nil }
        let expires = (o["expires_in"] as? Double) ?? Double(o["expires_in"] as? Int ?? 3600)
        return OAuthToken(accessToken: access, refreshToken: (o["refresh_token"] as? String) ?? previousRefresh,
                          expiresAt: now.addingTimeInterval(expires))
    }
}

// MARK: - Google Drive REST (v3) helpers

public enum GoogleDriveAPI {
    public static let base = "https://www.googleapis.com/drive/v3"
    public static let uploadBase = "https://www.googleapis.com/upload/drive/v3/files"
    static let fields = "files(id,name,mimeType,size,modifiedTime,webViewLink,quotaBytesUsed),nextPageToken"

    /// Escapes a value for a Drive `q` string literal.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    public static func searchURL(query: String, pageSize: Int = 20) -> URL? {
        var c = URLComponents(string: base + "/files")
        let q = "name contains '\(escape(query))' and trashed = false"
        c?.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "pageSize", value: String(pageSize)),
                         URLQueryItem(name: "fields", value: fields),
                         URLQueryItem(name: "orderBy", value: "modifiedTime desc")]
        return c?.url
    }

    public static func largeFilesURL(pageSize: Int = 50) -> URL? {
        var c = URLComponents(string: base + "/files")
        c?.queryItems = [URLQueryItem(name: "q", value: "trashed = false and 'me' in owners"),
                         URLQueryItem(name: "orderBy", value: "quotaBytesUsed desc"),
                         URLQueryItem(name: "pageSize", value: String(pageSize)),
                         URLQueryItem(name: "fields", value: fields)]
        return c?.url
    }

    public static let aboutURL = URL(string: base + "/about?fields=storageQuota,user(displayName,emailAddress)")!

    public static func parseFiles(_ data: Data) -> [CloudFile] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = o["files"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return files.compactMap { f in
            guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
            let size = Int64((f["quotaBytesUsed"] as? String) ?? (f["size"] as? String) ?? "")
            let date = (f["modifiedTime"] as? String).flatMap { iso.date(from: $0) }
            return CloudFile(id: id, service: .googleDrive, name: name, mimeType: f["mimeType"] as? String,
                             size: size, modified: date,
                             webURL: (f["webViewLink"] as? String) ?? "https://drive.google.com/open?id=\(id)")
        }
    }

    public static func parseUsage(_ data: Data) -> (CloudUsage, String?)? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = o["storageQuota"] as? [String: Any] else { return nil }
        func n(_ k: String) -> Int64? { (q[k] as? String).flatMap { Int64($0) } }
        let user = (o["user"] as? [String: Any])?["emailAddress"] as? String
        return (CloudUsage(used: n("usage") ?? 0, limit: n("limit"), inTrash: n("usageInDriveTrash")), user)
    }

    /// multipart/related body for a simple upload (files up to ~5 MB are fine; larger
    /// files use the same call — Drive accepts multipart up to 5 TB, but memory use grows).
    public static func multipartBody(name: String, mimeType: String, data: Data, boundary: String) -> Data {
        var body = Data()
        let meta = (try? JSONSerialization.data(withJSONObject: ["name": name])) ?? Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(meta)
        add("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        add("\r\n--\(boundary)--\r\n")
        return body
    }
}

// MARK: - SHA-256 (portable; CryptoKit isn't on Linux and the core must build there)

public enum SwoopSHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var m = message
        let bitLen = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(m[b]) << 24 | UInt32(m[b + 1]) << 16 | UInt32(m[b + 2]) << 8 | UInt32(m[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }

    public static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
