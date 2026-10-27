// SPDX-License-Identifier: MIT
import Foundation

/// A text snippet. Typing `keyword` anywhere expands it (when expansion is on), or
/// pick it from the "Search Snippets" command.
public struct Snippet: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var keyword: String
    public var text: String

    public init(id: UUID = UUID(), name: String, keyword: String, text: String) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.text = text
    }

    public static let examples: [Snippet] = [
        Snippet(name: "Today's date", keyword: ";date", text: "{date}"),
        Snippet(name: "Email signature", keyword: ";sig", text: "Best,\n{clipboard}"),
        Snippet(name: "Shrug", keyword: ";shrug", text: "¯\\_(ツ)_/¯"),
    ]
}

/// The result of an expansion: final text, and how many characters from the end the
/// caret should move back (for a `{cursor}` placeholder).
public struct Expansion: Equatable {
    public let text: String
    public let cursorOffsetFromEnd: Int
}

public enum SnippetExpander {
    /// Placeholders: {date} {time} {datetime} {day} {clipboard} {cursor}
    /// {date:FORMAT} (e.g. {date:yyyy-MM-dd}), {uuid}. Unknown placeholders are left as is.
    public static func expand(_ template: String, now: Date = Date(), clipboard: String? = nil,
                              locale: Locale = Locale(identifier: "en_GB"),
                              timeZone: TimeZone = .current,
                              uuid: () -> String = { UUID().uuidString }) -> Expansion {
        var out = ""
        var cursorAt: Int?
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{", let close = template[i...].firstIndex(of: "}") {
                let token = String(template[template.index(after: i)..<close])
                if let replacement = value(for: token, now: now, clipboard: clipboard, locale: locale,
                                           timeZone: timeZone, uuid: uuid) {
                    out += replacement
                    i = template.index(after: close)
                    continue
                }
                if token == "cursor" {
                    cursorAt = out.count
                    i = template.index(after: close)
                    continue
                }
            }
            out.append(ch)
            i = template.index(after: i)
        }
        let offset = cursorAt.map { out.count - $0 } ?? 0
        return Expansion(text: out, cursorOffsetFromEnd: offset)
    }

    static func value(for token: String, now: Date, clipboard: String?, locale: Locale,
                      timeZone: TimeZone, uuid: () -> String) -> String? {
        func fmt(_ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f.string(from: now)
        }
        func styled(_ d: DateFormatter.Style, _ t: DateFormatter.Style) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.dateStyle = d
            f.timeStyle = t
            return f.string(from: now)
        }
        switch token {
        case "date": return styled(.medium, .none)
        case "time": return styled(.none, .short)
        case "datetime": return styled(.medium, .short)
        case "day": return fmt("EEEE")
        case "clipboard": return clipboard ?? ""
        case "uuid": return uuid()
        default:
            if token.hasPrefix("date:") { return fmt(String(token.dropFirst(5))) }
            return nil
        }
    }
}

/// Watches typed characters and reports when the text just typed ends with a keyword.
public struct SnippetMatcher {
    public private(set) var buffer = ""
    public let maxLength: Int

    public init(maxLength: Int = 64) { self.maxLength = maxLength }

    /// Feed typed text (one key's characters). Returns the snippet whose keyword the
    /// buffer now ends with, longest keyword first. The buffer is cleared on a match.
    public mutating func feed(_ typed: String, snippets: [Snippet]) -> Snippet? {
        for ch in typed {
            if ch == "\u{8}" || ch == "\u{7F}" {   // backspace / delete
                if !buffer.isEmpty { buffer.removeLast() }
            } else if ch == "\r" || ch == "\n" || ch == "\t" {
                buffer = ""
            } else {
                buffer.append(ch)
            }
        }
        if buffer.count > maxLength { buffer = String(buffer.suffix(maxLength)) }
        let candidates = snippets.filter { !$0.keyword.isEmpty }.sorted { $0.keyword.count > $1.keyword.count }
        for s in candidates where buffer.hasSuffix(s.keyword) {
            buffer = ""
            return s
        }
        return nil
    }

    public mutating func reset() { buffer = "" }
}
