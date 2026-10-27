#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Sanity-checks Safari content-blocker JSON: rule count limit, url-filter regex subset,
# trigger/action shape, and that every chunk ends with its exceptions.  usage: check-safari.py blocker-*.json
import json, re, sys

LIMIT = 150_000
problems = 0
for path in sys.argv[1:]:
    rules = json.load(open(path))
    def bad(msg, r):
        global problems
        problems += 1
        if problems <= 25: print(f"{path}: {msg}: {json.dumps(r)[:200]}")
    if not rules: bad("empty list (Safari rejects it)", {})
    if len(rules) > LIMIT: bad(f"{len(rules)} rules > {LIMIT}", {})
    seen_exception = False
    for r in rules:
        t, a = r.get("trigger", {}), r.get("action", {})
        uf = t.get("url-filter")
        if uf is None: bad("missing url-filter", r); continue
        if not uf.isascii(): bad("non-ASCII url-filter", r)
        stripped = re.sub(r"\[[^\]]*\]", "", uf.replace("\\\\", "").replace("\\|", "").replace("\\{", "").replace("\\}", ""))
        if "|" in stripped or "{" in stripped or "(?" in uf: bad("regex feature Safari doesn't support", r)
        try: re.compile(uf)
        except re.error as e: bad(f"invalid regex ({e})", r)
        if "if-domain" in t and "unless-domain" in t: bad("if-domain and unless-domain together", r)
        for k in ("if-domain", "unless-domain"):
            for d in t.get(k, []):
                if d != d.lower() or not d.isascii(): bad(f"bad domain {d}", r)
        typ = a.get("type")
        if typ not in ("block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https"): bad("bad action", r)
        if typ == "css-display-none" and not a.get("selector"): bad("css-display-none without selector", r)
        if typ == "ignore-previous-rules": seen_exception = True
        elif seen_exception: bad("blocking rule after an exception (it can't be overridden)", r)
    print(f"{path}: {len(rules)} rules")
print(f"{problems} problems")
sys.exit(1 if problems else 0)
