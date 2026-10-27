#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Checks declarativeNetRequest rulesets against the constraints Chrome enforces at load time
# (so a bad rule doesn't stop the whole extension from loading).  usage: check-dnr.py rules/*.json
import json, re, sys

VALID_TYPES = {"main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object", "xmlhttprequest",
               "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other"}
problems = 0
total = 0
for path in sys.argv[1:]:
    rules = json.load(open(path))
    ids = set()
    for r in rules:
        total += 1
        def bad(msg):
            global problems
            problems += 1
            if problems <= 25:
                print(f"{path}: rule {r.get('id')}: {msg}: {json.dumps(r)[:200]}")
        if r["id"] in ids: bad("duplicate id")
        ids.add(r["id"])
        if r.get("priority", 1) < 1: bad("priority < 1")
        c = r["condition"]
        if r["action"]["type"] not in {"block", "allow", "allowAllRequests", "upgradeScheme", "redirect", "modifyHeaders"}: bad("action")
        uf = c.get("urlFilter")
        if uf is not None:
            if not uf: bad("empty urlFilter")
            if not uf.isascii(): bad("non-ASCII urlFilter")
            if uf.startswith("||*"): bad("urlFilter starts with ||*")
            body = uf[2:] if uf.startswith("||") else uf[1:] if uf.startswith("|") else uf
            body = body[:-1] if body.endswith("|") else body
            if "|" in body: bad("'|' inside urlFilter")
        if "regexFilter" in c and "urlFilter" in c: bad("both regexFilter and urlFilter")
        for k in ("requestDomains", "initiatorDomains", "excludedInitiatorDomains", "excludedRequestDomains"):
            v = c.get(k)
            if v is None: continue
            if not v and k in ("requestDomains", "initiatorDomains"): bad(f"empty {k}")
            for d in v:
                if not d or d != d.lower() or "*" in d or not d.isascii() or "/" in d: bad(f"bad domain in {k}: {d!r}")
        for k in ("resourceTypes", "excludedResourceTypes"):
            v = c.get(k)
            if v is None: continue
            if not v and k == "resourceTypes": bad("empty resourceTypes")
            for t in v:
                if t not in VALID_TYPES: bad(f"bad resource type {t}")
        if r["action"]["type"] == "allowAllRequests":
            rt = c.get("resourceTypes") or []
            if not rt or any(t not in ("main_frame", "sub_frame") for t in rt): bad("allowAllRequests needs main_frame/sub_frame only")
        if c.get("domainType") not in (None, "firstParty", "thirdParty"): bad("domainType")
print(f"{total} rules checked, {problems} problems")
sys.exit(1 if problems else 0)
