// SPDX-License-Identifier: MIT
//
// swoop-shield-compile: download (or read cached) filter lists, verify them, and write
//   <out>/shield.swsh                 binary DNS index (system extension / local resolver)
//   <out>/safari/blocker-N.json       Safari content-blocker chunks
//   <out>/webext/rules/swoop_N.json   declarativeNetRequest rulesets
//   <out>/webext/rulesets.json        ruleset ids (scripts/build-webext.sh puts them in the manifests)
//   <out>/webext/cosmetic.json        cosmetic + scriptlet data for the content scripts
//   <out>/lists.json, report.json     what was used (SHA-256, rule counts) and what was skipped
//
//   swoop-shield-compile --download --out build/shield
//   swoop-shield-compile --from ~/lists --lists easylist,easyprivacy --out /tmp/s
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShieldCore

func usage() -> Never {
    print("""
    usage: swoop-shield-compile [--download | --from DIR | --builtin-only] [--lists id,id,…|all|default] [--out DIR]
                                [--no-browser] [--safari-chunk N] [--safari-count N]
    lists: \(FilterListCatalog.all.map { $0.id }.joined(separator: ", "))
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var fromDir: String?
var download = false
var listArg = "default"
var outDir = "build/shield"
var browser = true
var safariChunk = SafariConverter.defaultChunkSize
var safariCount = SafariConverter.defaultChunkCount
var builtinOnly = false
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String { guard !args.isEmpty else { usage() }; return args.removeFirst() }
    switch a {
    case "--from": fromDir = value()
    case "--download": download = true
    case "--lists": listArg = value()
    case "--out": outDir = value()
    case "--no-browser": browser = false
    case "--builtin-only": builtinOnly = true
    case "--safari-chunk": safariChunk = Int(value()) ?? safariChunk
    case "--safari-count": safariCount = Int(value()) ?? safariCount
    case "-h", "--help": usage()
    default: print("unknown option \(a)"); usage()
    }
}
guard download || fromDir != nil || builtinOnly else { usage() }

var ids: [String]
switch listArg {
case "all": ids = FilterListCatalog.all.map { $0.id }
case "default": ids = FilterListCatalog.defaultEnabledIDs
default: ids = listArg.split(separator: ",").map(String.init)
}

func fetch(_ url: String) -> Data? {
    guard let u = URL(string: url) else { return nil }
    var req = URLRequest(url: u, timeoutInterval: 60)
    req.setValue("Swoop-Shield/0.2 (+https://swoopkey.com)", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var d: Data? }
    let box = Box()
    URLSession.shared.dataTask(with: req) { d, r, _ in
        if let h = r as? HTTPURLResponse, h.statusCode == 200 { box.d = d }
        sem.signal()
    }.resume()
    sem.wait()
    return box.d
}

if builtinOnly { ids = [] }
let fm = FileManager.default
var texts: [ListText] = []
var records: [ListRecord] = []
var failures: [String: String] = [:]
for id in ids {
    guard let src = FilterListCatalog.source(id: id) else { print("unknown list \(id)"); exit(2) }
    var got: (ListRecord, String)?
    if let dir = fromDir {
        let path = (dir as NSString).appendingPathComponent("\(id).txt")
        guard let d = fm.contents(atPath: path) else { failures[id] = "missing \(path)"; continue }
        switch ListIntegrity.verify(data: d, source: src, fetchedFrom: src.urls[0], previous: nil) {
        case .success(let r): got = r
        case .failure(let e): failures[id] = e.description
        }
    } else {
        for url in src.urls {
            guard let d = fetch(url) else { failures[id] = "download failed: \(url)"; continue }
            switch ListIntegrity.verify(data: d, source: src, fetchedFrom: url, previous: nil) {
            case .success(let r): got = r; failures[id] = nil
            case .failure(let e): failures[id] = "\(url): \(e.description)"
            }
            if got != nil { break }
        }
    }
    if let (rec, text) = got {
        records.append(rec)
        texts.append(ListText(source: src, text: text))
        print("✓ \(id): \(rec.ruleCount) rules (\(rec.dnsRuleCount) DNS) sha256 \(rec.sha256.prefix(16))…")
    } else {
        print("✗ \(id): \(failures[id] ?? "failed")")
    }
}
guard !texts.isEmpty || builtinOnly else { print("no lists"); exit(1) }

let compiled: CompiledShield
do {
    compiled = try ShieldCompiler.compile(texts, options: .init(buildBrowser: browser, safariChunkSize: safariChunk, safariChunkCount: safariCount))
} catch {
    print("compile failed: \(error)"); exit(1)
}

func write(_ data: Data, _ rel: String) {
    let path = (outDir as NSString).appendingPathComponent(rel)
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard fm.createFile(atPath: path, contents: data) else { print("can't write \(path)"); exit(1) }
}
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
enc.dateEncodingStrategy = .iso8601

write(compiled.index, "shield.swsh")
if let s = compiled.safari {
    for (i, chunk) in s.chunks.enumerated() { write(SafariConverter.json(chunk), "safari/blocker-\(i + 1).json") }
}
if let d = compiled.dnr {
    for rs in d.rulesets { write(DNRConverter.json(rs.rules), "webext/rules/\(rs.id).json") }
    write((try? enc.encode(d.rulesets.map { ["id": $0.id, "path": "rules/\($0.id).json", "rules": "\($0.rules.count)"] })) ?? Data(), "webext/rulesets.json")
}
if let c = compiled.cosmetic { write(c.json(), "webext/cosmetic.json") }
write((try? enc.encode(records)) ?? Data(), "lists.json")
var report = compiled.report
for (k, v) in failures { report.skipped["list failed: \(k): \(v)"] = 1 }
write((try? enc.encode(report)) ?? Data(), "report.json")

print("""
index: \(report.dnsDomains) domains + \(report.dnsComplex) complex rules, \(report.indexBytes / 1024) KB
safari: \(report.safariRules) rules in \(compiled.safari?.chunks.count ?? 0) blockers (\(report.safariDropped) didn't fit)
dnr: \(report.dnrRules) rules · cosmetic selectors: \(report.cosmeticSelectors)
compiled in \(String(format: "%.1f", report.seconds)) s → \(outDir)
""")
if !failures.isEmpty { exit(3) }
