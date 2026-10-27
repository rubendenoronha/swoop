// SPDX-License-Identifier: MIT
import Foundation

/// A Raycast-compatible script command: any executable script with `@raycast.*`
/// metadata comments in its header, e.g.
///
///     #!/bin/bash
///     # @raycast.schemaVersion 1
///     # @raycast.title Say Hello
///     # @raycast.mode compact
///     # @raycast.argument1 { "type": "text", "placeholder": "Name" }
///
/// Swoop reads title, mode, packageName, icon, description, argument1…3,
/// needsConfirmation and refreshTime (ignored). Unknown keys are kept in `extra`.
public struct ScriptCommand: Equatable, Identifiable {
    public enum Mode: String, Equatable {
        case fullOutput, compact, silent, inline
    }

    public struct Argument: Equatable {
        public let type: String
        public let placeholder: String
        public let optional: Bool
        public let percentEncoded: Bool
    }

    public var id: String { path }
    public let path: String
    public let title: String
    public let mode: Mode
    public let packageName: String?
    public let icon: String?
    public let description: String?
    public let arguments: [Argument]
    public let needsConfirmation: Bool
    public let extra: [String: String]
}

public enum ScriptCommandParser {
    /// Parses the first 60 lines of a script. Returns nil unless it has at least a
    /// title and schemaVersion (as Raycast requires) and a valid mode.
    public static func parse(_ contents: String, path: String) -> ScriptCommand? {
        var meta: [String: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(60) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let r = t.range(of: "@raycast.") else { continue }
            // Must be a comment: #, //, --, ;, or inside a block comment line.
            let before = t[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            guard before.isEmpty || before.hasPrefix("#") || before.hasPrefix("//") || before.hasPrefix("--")
                || before.hasPrefix(";") || before.hasPrefix("*") || before.hasPrefix("/*") || before.hasPrefix("'")
                || before.hasPrefix("REM") else { continue }
            let rest = t[r.upperBound...]
            guard let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let key = String(rest[..<space])
            var value = rest[space...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix("*/") { value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces) }
            meta[key] = value
        }
        guard meta["schemaVersion"] != nil, let title = meta["title"], !title.isEmpty else { return nil }
        let mode = ScriptCommand.Mode(rawValue: meta["mode"] ?? "fullOutput") ?? .fullOutput
        var args: [ScriptCommand.Argument] = []
        for i in 1...3 {
            guard let raw = meta["argument\(i)"], let a = parseArgument(raw) else { continue }
            args.append(a)
        }
        let known: Set<String> = ["schemaVersion", "title", "mode", "packageName", "icon", "description",
                                  "argument1", "argument2", "argument3", "needsConfirmation"]
        return ScriptCommand(
            path: path, title: title, mode: mode, packageName: meta["packageName"], icon: meta["icon"],
            description: meta["description"], arguments: args,
            needsConfirmation: meta["needsConfirmation"] == "true",
            extra: meta.filter { !known.contains($0.key) })
    }

    static func parseArgument(_ json: String) -> ScriptCommand.Argument? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ScriptCommand.Argument(
            type: obj["type"] as? String ?? "text",
            placeholder: obj["placeholder"] as? String ?? "Argument",
            optional: obj["optional"] as? Bool ?? false,
            percentEncoded: obj["percentEncoded"] as? Bool ?? false)
    }

    /// The interpreter to run a script with when it isn't executable: from the shebang,
    /// else by extension. Returns [launchPath, args...] to prefix the script path with.
    public static func interpreter(for contents: String, path: String) -> [String] {
        if let first = contents.split(separator: "\n").first, first.hasPrefix("#!") {
            let parts = first.dropFirst(2).split(separator: " ").map(String.init)
            if !parts.isEmpty { return parts }
        }
        switch (path as NSString).pathExtension.lowercased() {
        case "py": return ["/usr/bin/env", "python3"]
        case "rb": return ["/usr/bin/env", "ruby"]
        case "js": return ["/usr/bin/env", "node"]
        case "swift": return ["/usr/bin/env", "swift"]
        case "applescript", "scpt": return ["/usr/bin/osascript"]
        case "zsh": return ["/bin/zsh"]
        default: return ["/bin/bash"]
        }
    }

    /// For compact/inline modes Raycast shows the last line of output.
    public static func lastLine(of output: String) -> String {
        output.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// A quicklink: a URL (or file path / app URL scheme) with optional `{query}` /
/// `{argument}` placeholders, e.g. "https://github.com/search?q={query}".
public struct Quicklink: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var template: String
    public var keyword: String

    public init(id: UUID = UUID(), name: String, template: String, keyword: String = "") {
        self.id = id
        self.name = name
        self.template = template
        self.keyword = keyword
    }

    public var needsQuery: Bool {
        template.contains("{query}") || template.contains("{argument}") || template.contains("{argument ")
    }

    /// Fills placeholders (percent-encoded for http(s) URLs) and returns the final URL string.
    public func resolve(query: String) -> String {
        let isWeb = template.lowercased().hasPrefix("http")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let value = isWeb ? (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query) : query
        var out = template.replacingOccurrences(of: "{query}", with: value)
            .replacingOccurrences(of: "{argument}", with: value)
        // Raycast style {argument name="x"}
        while let r = out.range(of: "{argument "), let close = out[r.lowerBound...].firstIndex(of: "}") {
            out.replaceSubrange(r.lowerBound...close, with: value)
        }
        return out
    }

    public static let defaults: [Quicklink] = [
        Quicklink(name: "Search Google", template: "https://www.google.com/search?q={query}", keyword: "g"),
        Quicklink(name: "Search DuckDuckGo", template: "https://duckduckgo.com/?q={query}", keyword: "ddg"),
        Quicklink(name: "Search GitHub", template: "https://github.com/search?q={query}", keyword: "gh"),
        Quicklink(name: "Search YouTube", template: "https://www.youtube.com/results?search_query={query}", keyword: "yt"),
        Quicklink(name: "Search Wikipedia", template: "https://en.wikipedia.org/w/index.php?search={query}", keyword: "wiki"),
        Quicklink(name: "Search Apple Maps", template: "maps://?q={query}", keyword: "map"),
    ]
}
