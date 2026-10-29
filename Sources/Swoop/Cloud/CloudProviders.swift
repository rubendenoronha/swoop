// SPDX-License-Identifier: MIT
import AppKit
import Network
import SwoopCore

/// One cloud service. Google Drive and iCloud Drive (local folder) are implemented; a
/// Dropbox or OneDrive provider only needs these five things (their OAuth flows use the
/// same OAuthFlow/PKCE/LoopbackServer pieces).
protocol CloudProvider: AnyObject {
    var service: CloudService { get }
    var isSignedIn: Bool { get }
    var accountName: String? { get }
    func search(_ query: String, completion: @escaping ([CloudFile]) -> Void)
    func usage(completion: @escaping (CloudUsage?) -> Void)
    func largeFiles(completion: @escaping ([CloudFile]) -> Void)
}

final class CloudManager: ObservableObject {
    static let shared = CloudManager()
    let drive = GoogleDriveProvider()
    let icloud = ICloudDriveProvider()
    @Published var lastUpload: String?

    var providers: [CloudProvider] { [drive, icloud] }

    func provider(_ s: CloudService) -> CloudProvider? { providers.first { $0.service == s } }

    func search(_ q: String, service: CloudService, completion: @escaping ([CloudFile]) -> Void) {
        guard let p = provider(service), p.isSignedIn else { completion([]); return }
        p.search(q) { files in DispatchQueue.main.async { completion(files) } }
    }

    func quickUpload() {
        guard drive.isSignedIn else {
            if Actions.confirm("Sign in to Google Drive?", "Swoop opens Google's sign-in page in your browser. Tokens stay in your Keychain.",
                               ok: "Sign In") { drive.signIn() }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files to upload to Google Drive"
        guard panel.runModal() == .OK else { return }
        for u in panel.urls { upload(u) }
    }

    func upload(_ url: URL) {
        guard drive.isSignedIn else { quickUpload(); return }
        Notifier.show("Uploading \(url.lastPathComponent)…")
        drive.upload(url) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let link):
                    self.lastUpload = link
                    if let l = link { Actions.copy(l) }
                    Notifier.show("Uploaded \(url.lastPathComponent)", body: link == nil ? nil : "Link copied to the clipboard.")
                case .failure(let e):
                    Notifier.show("Upload failed", body: e.localizedDescription)
                }
            }
        }
    }

    func openICloudFolder() {
        let u = URL(fileURLWithPath: icloud.root)
        if FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.open(u) } else {
            Notifier.show("iCloud Drive isn't turned on", body: "System Settings › Apple ID › iCloud › iCloud Drive")
        }
    }
}

// MARK: - Google Drive

struct SimpleError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Swoop's own Google OAuth "Desktop app" client, so users only need to sign in.
/// Google treats installed-app client secrets as non-confidential (they ship inside the
/// app, and PKCE protects each sign-in). A build can override it with the Info.plist keys
/// SwoopGoogleClientID / SwoopGoogleClientSecret (GOOGLE_CLIENT_ID / _SECRET at build time).
enum GoogleClient {
    static let defaultID = "__SWOOP_GOOGLE_CLIENT_ID__"
    static let defaultSecretParts = ["__SWOOP_GOOGLE_SECRET_A__", "__SWOOP_GOOGLE_SECRET_B__"]

    static var builtIn: (id: String, secret: String)? {
        let plistID = (Bundle.main.object(forInfoDictionaryKey: "SwoopGoogleClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !plistID.isEmpty {
            let secret = Bundle.main.object(forInfoDictionaryKey: "SwoopGoogleClientSecret") as? String ?? ""
            return (plistID, secret)
        }
        guard !defaultID.hasPrefix("__") else { return nil }
        return (defaultID, defaultSecretParts.joined())
    }
}

final class GoogleDriveProvider: ObservableObject, CloudProvider {
    let service = CloudService.googleDrive
    private let keychainAccount = "google-drive"
    @Published private(set) var token: OAuthToken?
    @Published private(set) var accountName: String?
    @Published private(set) var signingIn = false
    private var server: LoopbackServer?

    init() {
        if let d = Keychain.get(account: keychainAccount), let t = try? JSONDecoder().decode(OAuthToken.self, from: d) {
            token = t
        }
        accountName = UserDefaults.standard.string(forKey: "googleDriveAccount")
    }

    var isSignedIn: Bool { token != nil }

    /// Your own client if you set one in Settings › Cloud › Advanced, otherwise Swoop's built-in one.
    private var config: OAuthConfig? {
        let id = Prefs.shared.googleClientID.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty {
            let secret = Prefs.shared.googleClientSecret.trimmingCharacters(in: .whitespaces)
            return OAuthConfig.googleDrive(clientID: id, clientSecret: secret.isEmpty ? nil : secret)
        }
        guard let c = GoogleClient.builtIn else { return nil }
        return OAuthConfig.googleDrive(clientID: c.id, clientSecret: c.secret)
    }

    var canSignIn: Bool { config != nil }

    func signIn() {
        guard let cfg = config else {
            Actions.info("Google sign-in isn't available in this build",
                         "Add your own Google client in Swoop Settings › Cloud › Advanced.")
            SettingsWindow.show(tab: .cloud)
            return
        }
        server?.stop()
        signingIn = true
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = UUID().uuidString
        let srv = LoopbackServer()
        server = srv
        do {
            try srv.start(onReady: { port in
                let redirect = "http://127.0.0.1:\(port)"
                guard let url = OAuthFlow.authorizationURL(cfg, redirectURI: redirect, state: state, challenge: challenge) else { return }
                NSWorkspace.shared.open(url)
            }, onRequest: { [weak self] line, port in
                guard let self = self else { return "" }
                guard line.contains("code=") || line.contains("error=") else { return "" }
                let redirect = "http://127.0.0.1:\(port)"
                switch OAuthFlow.parseRedirect(requestLine: line, expectedState: state) {
                case .success(let code):
                    self.exchange(cfg, code: code, verifier: verifier, redirect: redirect)
                    return GoogleDriveProvider.page("Signed in to Google Drive", "You can close this tab and go back to Swoop.")
                case .failure(let e):
                    DispatchQueue.main.async { self.signingIn = false; self.server?.stop() }
                    return GoogleDriveProvider.page("Sign-in didn't finish", "\(e)")
                }
            })
        } catch {
            signingIn = false
            Actions.info("Couldn't start sign-in", error.localizedDescription)
        }
    }

    static func page(_ title: String, _ body: String) -> String {
        "<!doctype html><meta charset=utf-8><title>Swoop</title><body style=\"font:16px -apple-system;margin:15vh auto;max-width:420px;text-align:center\"><h2>\(title)</h2><p>\(body)</p></body>"
    }

    private func exchange(_ cfg: OAuthConfig, code: String, verifier: String, redirect: String) {
        var req = URLRequest(url: URL(string: cfg.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = OAuthFlow.tokenRequestBody(cfg, code: code, verifier: verifier, redirectURI: redirect)
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                self.signingIn = false
                self.server?.stop()
                guard let d = data, let t = OAuthToken.parse(d) else {
                    let msg = err?.localizedDescription ?? data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response"
                    Actions.info("Google sign-in failed", msg)
                    return
                }
                self.store(t)
                self.fetchAccount()
                Prefs.shared.cloudSearchInLauncher = true
                Notifier.show("Google Drive connected")
            }
        }.resume()
    }

    private func store(_ t: OAuthToken) {
        token = t
        if let d = try? JSONEncoder().encode(t) { Keychain.set(d, account: keychainAccount) }
    }

    func signOut() {
        if let t = token?.refreshToken ?? token?.accessToken,
           let u = URL(string: "https://oauth2.googleapis.com/revoke?token=\(t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? t)") {
            var r = URLRequest(url: u)
            r.httpMethod = "POST"
            URLSession.shared.dataTask(with: r).resume()
        }
        token = nil
        accountName = nil
        UserDefaults.standard.removeObject(forKey: "googleDriveAccount")
        Keychain.delete(account: keychainAccount)
    }

    /// A fresh access token (refreshing it when it's about to expire).
    func withAccessToken(_ body: @escaping (String?) -> Void) {
        guard let t = token else { body(nil); return }
        guard t.isExpired() else { body(t.accessToken); return }
        guard let cfg = config, let refresh = t.refreshToken else { body(nil); return }
        var req = URLRequest(url: URL(string: cfg.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = OAuthFlow.refreshRequestBody(cfg, refreshToken: refresh)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                if let d = data, let nt = OAuthToken.parse(d, previousRefresh: refresh) {
                    self.store(nt)
                    body(nt.accessToken)
                } else {
                    body(nil)
                }
            }
        }.resume()
    }

    private func get(_ url: URL, completion: @escaping (Data?) -> Void) {
        withAccessToken { access in
            guard let a = access else { completion(nil); return }
            var r = URLRequest(url: url)
            r.setValue("Bearer \(a)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: r) { d, resp, _ in
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                completion(ok ? d : nil)
            }.resume()
        }
    }

    private func fetchAccount() {
        get(GoogleDriveAPI.aboutURL) { d in
            guard let d = d, let parsed = GoogleDriveAPI.parseUsage(d) else { return }
            let who = parsed.1
            DispatchQueue.main.async {
                self.accountName = who
                UserDefaults.standard.set(who, forKey: "googleDriveAccount")
            }
        }
    }

    func search(_ query: String, completion: @escaping ([CloudFile]) -> Void) {
        guard let u = GoogleDriveAPI.searchURL(query: query) else { completion([]); return }
        get(u) { d in completion(d.map(GoogleDriveAPI.parseFiles) ?? []) }
    }

    func usage(completion: @escaping (CloudUsage?) -> Void) {
        get(GoogleDriveAPI.aboutURL) { d in completion(d.flatMap(GoogleDriveAPI.parseUsage)?.0) }
    }

    func largeFiles(completion: @escaping ([CloudFile]) -> Void) {
        guard let u = GoogleDriveAPI.largeFilesURL() else { completion([]); return }
        get(u) { d in completion(d.map(GoogleDriveAPI.parseFiles) ?? []) }
    }

    func upload(_ file: URL, completion: @escaping (Result<String?, Error>) -> Void) {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            completion(.failure(SimpleError("Couldn't read \(file.lastPathComponent)")))
            return
        }
        let mime = MimeTypes.forExtension(file.pathExtension)
        withAccessToken { access in
            guard let a = access else { completion(.failure(SimpleError("Not signed in"))); return }
            let boundary = "swoop-" + UUID().uuidString
            var r = URLRequest(url: URL(string: GoogleDriveAPI.uploadBase + "?uploadType=multipart&fields=id,name,webViewLink")!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(a)", forHTTPHeaderField: "Authorization")
            r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let body = GoogleDriveAPI.multipartBody(name: file.lastPathComponent, mimeType: mime, data: data, boundary: boundary)
            URLSession.shared.uploadTask(with: r, from: body) { d, resp, err in
                if let e = err { completion(.failure(e)); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code), let d = d else {
                    completion(.failure(SimpleError("Google Drive answered \(code)")))
                    return
                }
                let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                completion(.success(obj?["webViewLink"] as? String))
            }.resume()
        }
    }
}

enum MimeTypes {
    static func forExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "txt", "md": return "text/plain"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }
}

/// One-shot HTTP listener on 127.0.0.1 (random port) for the OAuth redirect (RFC 8252 §7.3).
final class LoopbackServer {
    private var listener: NWListener?
    private var port: UInt16 = 0

    func start(onReady: @escaping (UInt16) -> Void, onRequest: @escaping (String, UInt16) -> String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = l.port?.rawValue {
                self?.port = p
                DispatchQueue.main.async { onReady(p) }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let line = text.components(separatedBy: "\r\n").first ?? ""
                var body = onRequest(line, self?.port ?? 0)
                let status = body.isEmpty ? "404 Not Found" : "200 OK"
                if body.isEmpty { body = "Not found" }
                let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - iCloud Drive (local folder)

final class ICloudDriveProvider: CloudProvider {
    let service = CloudService.iCloudDrive
    let root = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
    var isSignedIn: Bool { FileManager.default.fileExists(atPath: root) }
    var accountName: String? { isSignedIn ? "This Mac's iCloud Drive folder" : nil }

    private func walk(limit: Int = 60_000, _ visit: (URL, URLResourceValues) -> Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey,
                                      .ubiquitousItemDownloadingStatusKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var n = 0
        for case let u as URL in e {
            n += 1
            if n > limit { break }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if !visit(u, v) { break }
        }
    }

    private func file(_ u: URL, _ v: URLResourceValues) -> CloudFile {
        CloudFile(id: u.path, service: .iCloudDrive, name: u.lastPathComponent,
                  size: Int64(v.fileSize ?? v.totalFileAllocatedSize ?? 0), modified: v.contentModificationDate,
                  webURL: nil, localPath: u.path)
    }

    func search(_ query: String, completion: @escaping ([CloudFile]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [CloudFile] = []
            self.walk { u, v in
                if u.lastPathComponent.localizedCaseInsensitiveContains(query) { out.append(self.file(u, v)) }
                return out.count < 20
            }
            completion(out)
        }
    }

    /// iCloud's account quota isn't exposed to apps; this is what the folder holds and
    /// how much of it is downloaded to this Mac.
    func usage(completion: @escaping (CloudUsage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var logical: Int64 = 0, local: Int64 = 0
            self.walk(limit: 400_000) { _, v in
                if v.isRegularFile == true {
                    logical += Int64(v.fileSize ?? 0)
                    local += Int64(v.totalFileAllocatedSize ?? 0)
                }
                return true
            }
            completion(CloudUsage(used: logical, limit: nil, inTrash: local))
        }
    }

    func largeFiles(completion: @escaping ([CloudFile]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var all: [CloudFile] = []
            self.walk(limit: 400_000) { u, v in
                if v.isRegularFile == true, (v.fileSize ?? 0) > 50_000_000 { all.append(self.file(u, v)) }
                return true
            }
            completion(Array(all.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(50)))
        }
    }
}
