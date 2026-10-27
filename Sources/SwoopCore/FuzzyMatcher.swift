// SPDX-License-Identifier: MIT
import Foundation

/// A small, fast fuzzy matcher in the spirit of Raycast / fzf.
///
/// Every query character must appear in the candidate in order (case-insensitive,
/// diacritic-insensitive). Matches score higher when they are consecutive, start a
/// word ("vs" → "Visual Studio"), or start the whole string. A whole-string prefix
/// match beats everything else, so typing "saf" puts Safari first.
public struct FuzzyMatch: Equatable {
    public let score: Double
    /// Indices (in Characters) of the candidate that matched the query.
    public let matchedIndices: [Int]
}

public enum FuzzyMatcher {
    /// Returns nil when the query does not match.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let q = Array(normalize(query).filter { !$0.isWhitespace })
        if q.isEmpty { return FuzzyMatch(score: 0, matchedIndices: []) }
        let original = Array(candidate)
        let c = Array(normalize(candidate))
        guard c.count == original.count, q.count <= c.count else {
            // Normalisation changed the length (rare ligatures): fall back to a plain compare.
            return plainMatch(q, Array(candidate.lowercased()))
        }
        return bestMatch(q, c, original)
    }

    /// Score a query against several fields (e.g. title + keywords); best one wins.
    /// Fields after the first are slightly discounted.
    public static func bestScore(_ query: String, fields: [String]) -> Double? {
        var best: Double?
        for (i, f) in fields.enumerated() {
            guard let m = match(query, in: f) else { continue }
            let s = i == 0 ? m.score : m.score * 0.8
            if best == nil || s > best! { best = s }
        }
        return best
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isBoundary(_ chars: [Character], _ i: Int, _ original: [Character]) -> Bool {
        if i == 0 { return true }
        let prev = chars[i - 1]
        if prev == " " || prev == "-" || prev == "_" || prev == "." || prev == "/" || prev == "(" { return true }
        // camelCase boundary: lower → Upper in the original string.
        let p = original[i - 1], cur = original[i]
        if p.isLowercase && cur.isUppercase { return true }
        if !p.isNumber && cur.isNumber { return true }
        return false
    }

    /// Greedy forward match from every possible start of the first character, keeping
    /// the best score. Candidates are short (app names, titles), so this is cheap.
    private static func bestMatch(_ q: [Character], _ c: [Character], _ original: [Character]) -> FuzzyMatch? {
        var best: FuzzyMatch?
        var start = 0
        while start < c.count {
            guard let first = c[start...].firstIndex(of: q[0]) else { break }
            if let m = scoreFrom(first, q, c, original), best == nil || m.score > best!.score {
                best = m
            }
            start = first + 1
        }
        return best
    }

    private static func scoreFrom(_ first: Int, _ q: [Character], _ c: [Character], _ original: [Character]) -> FuzzyMatch? {
        var indices: [Int] = [first]
        var ci = first + 1
        for qi in 1..<max(q.count, 1) where qi < q.count {
            // Prefer the next word-boundary occurrence if the immediate next char doesn't match.
            var found: Int?
            var j = ci
            while j < c.count {
                if c[j] == q[qi] {
                    if j == ci { found = j; break }
                    if found == nil { found = j }
                    if isBoundary(c, j, original) { found = j; break }
                }
                j += 1
            }
            guard let f = found else { return nil }
            indices.append(f)
            ci = f + 1
        }
        var score = 0.0
        var prev = -2
        for idx in indices {
            var s = 1.0
            if idx == prev + 1 { s += 2.0 }               // consecutive
            if isBoundary(c, idx, original) { s += 2.5 }  // word start
            if idx == 0 { s += 3.0 }                       // string start
            score += s
            prev = idx
        }
        // Penalise gaps and long candidates a little.
        let span = Double(indices.last! - indices.first! + 1 - indices.count)
        score -= span * 0.15
        score -= Double(c.count) * 0.02
        // Whole prefix bonus.
        if indices.first == 0 && indices == Array(0..<indices.count) { score += 5.0 }
        // Exact match bonus.
        if indices.count == c.count { score += 4.0 }
        return FuzzyMatch(score: score, matchedIndices: indices)
    }

    private static func plainMatch(_ q: [Character], _ c: [Character]) -> FuzzyMatch? {
        var idx: [Int] = []
        var ci = 0
        for ch in q {
            guard let f = c[ci...].firstIndex(where: { String($0).lowercased() == String(ch).lowercased() }) else { return nil }
            idx.append(f); ci = f + 1
        }
        return FuzzyMatch(score: Double(idx.count), matchedIndices: idx)
    }
}
