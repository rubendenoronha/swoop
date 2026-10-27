// SPDX-License-Identifier: MIT
import AppKit
import SwoopCore

/// Raycast-compatible script commands from a folder (default
/// ~/Library/Application Support/Swoop/Scripts). Each script with @raycast metadata
/// becomes a command (searchable, bindable to a hotkey).
final class ScriptCommands {
    static let shared = ScriptCommands()
    private(set) var scripts: [ScriptCommand] = []

    func reload() {
        let dir = Prefs.shared.scriptsFolder
        var out: [ScriptCommand] = []
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: dir) {
            for n in names.sorted() where !n.hasPrefix(".") {
                let p = (dir as NSString).appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
                      let attrs = try? fm.attributesOfItem(atPath: p), (attrs[.size] as? Int ?? 0) < 1_000_000,
                      let text = try? String(contentsOfFile: p, encoding: .utf8),
                      let cmd = ScriptCommandParser.parse(text, path: p) else { continue }
                out.append(cmd)
            }
        }
        scripts = out
        Providers.shared.invalidate()
        HotKeyCenter.shared.reload()
    }

    static func commandID(for s: ScriptCommand) -> String { "script." + (s.path as NSString).lastPathComponent }

    func script(forCommandID id: String) -> ScriptCommand? { scripts.first { Self.commandID(for: $0) == id } }

    var commands: [SwoopCommand] {
        scripts.map { s in
            SwoopCommand(id: Self.commandID(for: s), title: s.title,
                         subtitle: [s.packageName, s.description].compactMap { $0 }.joined(separator: " · "),
                         symbol: "terminal", keywords: [s.packageName ?? "", "script"], group: .scripts,
                         closesLauncher: !(s.mode == .fullOutput || !s.arguments.isEmpty)) { self.start(s) }
        }
    }

    func start(_ s: ScriptCommand) {
        if s.needsConfirmation && !Actions.confirm("Run \(s.title)?", s.path, ok: "Run") { return }
        if let arg = s.arguments.first {
            LauncherController.shared.show(mode: .argument(title: s.title, placeholder: arg.placeholder) { value in
                if value.isEmpty && !arg.optional { NSSound.beep(); return }
                let v = arg.percentEncoded ? (value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value) : value
                self.execute(s, args: [v])
            })
        } else {
            execute(s, args: [])
        }
    }

    private func execute(_ s: ScriptCommand, args: [String]) {
        let fm = FileManager.default
        let p = Process()
        if fm.isExecutableFile(atPath: s.path) {
            p.executableURL = URL(fileURLWithPath: s.path)
            p.arguments = args
        } else {
            let text = (try? String(contentsOfFile: s.path, encoding: .utf8)) ?? ""
            var interp = ScriptCommandParser.interpreter(for: text, path: s.path)
            p.executableURL = URL(fileURLWithPath: interp.removeFirst())
            p.arguments = interp + [s.path] + args
        }
        p.currentDirectoryURL = URL(fileURLWithPath: (s.path as NSString).deletingLastPathComponent)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        if s.mode == .fullOutput {
            LauncherController.shared.show(mode: .output(title: s.title, text: "Running…"))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var output = ""
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                output = String(data: data, encoding: .utf8) ?? ""
            } catch {
                output = "Couldn't run the script: \(error.localizedDescription)"
            }
            let status = p.isRunning ? 0 : p.terminationStatus
            DispatchQueue.main.async {
                switch s.mode {
                case .fullOutput:
                    LauncherController.shared.show(mode: .output(title: s.title, text: output.isEmpty ? "(no output)" : output))
                case .compact, .inline:
                    let line = ScriptCommandParser.lastLine(of: output)
                    Notifier.show(status == 0 ? (line.isEmpty ? "\(s.title) finished" : line) : "\(s.title) failed",
                                  body: status == 0 ? nil : line)
                case .silent:
                    if status != 0 { Notifier.show("\(s.title) failed", body: ScriptCommandParser.lastLine(of: output)) }
                }
            }
        }
    }

    /// Writes an example script so the folder isn't empty on first launch.
    func installExampleIfEmpty() {
        let dir = Prefs.shared.scriptsFolder
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: dir))?.filter({ !$0.hasPrefix(".") }).isEmpty ?? true else { return }
        let example = """
        #!/bin/bash

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Show My IP Address
        # @raycast.mode compact

        # Optional parameters:
        # @raycast.icon 🌐
        # @raycast.packageName Network
        # @raycast.description Your local network IP address

        ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo "Not connected"
        """
        let path = (dir as NSString).appendingPathComponent("my-ip.sh")
        try? example.write(toFile: path, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
