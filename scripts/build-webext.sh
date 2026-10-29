#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Assembles the Swoop Shield browser extension for Chromium browsers, Firefox and Safari:
#
#   ./scripts/build-webext.sh                 # built-in rules only (YouTube etc.), no third-party lists
#   ./scripts/build-webext.sh build/shield    # with rules compiled by swoop-shield-compile --out build/shield
#
# Output: dist/webext/{chromium,firefox,safari}/ and dist/Swoop-Shield-{chromium,firefox}-<version>.zip
# Filter-list data keeps its own licence; when compiled lists are included, ATTRIBUTION.md
# (list names, licences, sources) is added to every package.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Extensions/webext"
RULES="${1:-}"
OUT="$ROOT/dist/webext"
VERSION="${SWOOP_VERSION:-0.2.3}"
command -v python3 >/dev/null || { echo "build-webext: python3 is required" >&2; exit 1; }

rm -rf "$OUT"
for flavour in chromium firefox safari; do
  D="$OUT/$flavour"
  mkdir -p "$D/rules" "$D/icons"
  cp "$SRC"/{background.js,content.js,scriptlets.js,youtube.js,popup.html,popup.js} "$D/"
  cp "$SRC"/icons/*.png "$D/icons/"
  cp "$SRC/rules/swoop_builtin.json" "$D/rules/"
  if [[ -n "$RULES" && -f "$RULES/webext/cosmetic.json" ]]; then
    cp "$RULES/webext/cosmetic.json" "$D/cosmetic.json"
    cp "$RULES"/webext/rules/*.json "$D/rules/"
  else
    cp "$SRC/cosmetic.json" "$D/cosmetic.json"
  fi
  cp "$SRC/manifest.$flavour.json" "$D/manifest.json"
  cp "$ROOT/LICENSE" "$D/LICENSE"
  python3 - "$D" "$VERSION" "$flavour" "${RULES:-}" <<'PY'
import json, os, sys
d, version, flavour, rules = sys.argv[1:5]
m = json.load(open(os.path.join(d, "manifest.json")))
m["version"] = version
if flavour != "safari":
    res = [{"id": "swoop_builtin", "enabled": True, "path": "rules/swoop_builtin.json"}]
    for f in sorted(os.listdir(os.path.join(d, "rules"))):
        rid = f[:-5]
        if rid != "swoop_builtin":
            res.append({"id": rid, "enabled": True, "path": "rules/" + f})
    m["declarative_net_request"] = {"rule_resources": res}
else:
    # Safari: network blocking is done by the content blockers; no DNR rules here.
    for f in os.listdir(os.path.join(d, "rules")):
        os.remove(os.path.join(d, "rules", f))
    os.rmdir(os.path.join(d, "rules"))
json.dump(m, open(os.path.join(d, "manifest.json"), "w"), indent=2, sort_keys=True)
if rules and os.path.exists(os.path.join(rules, "lists.json")):
    lists = json.load(open(os.path.join(rules, "lists.json")))
    lines = ["# Filter list attribution", "",
             "This package contains rules compiled from these lists. Each list keeps its own licence.", ""]
    sys.path.insert(0, "")
    for rec in lists:
        lines.append(f"- {rec.get('title') or rec['id']} ({rec['id']}), version {rec.get('version') or '?'}, from {rec['sourceURL']}, SHA-256 {rec['sha256']}")
    lines += ["", "Licences: EasyList / EasyPrivacy: GPL-3.0 or CC BY-SA 3.0 (https://easylist.to/pages/licence.html);",
              "AdGuard DNS filter, HaGeZi, OISD: GPL-3.0; URLhaus (malware-filter): CC0-1.0 / MIT; AdGuard cname-trackers: MIT;",
              "Peter Lowe's list: free to use (https://pgl.yoyo.org/adservers/policy.php). Swoop's own code and rules: MIT."]
    open(os.path.join(d, "ATTRIBUTION.md"), "w").write("\n".join(lines) + "\n")
PY
done

mkdir -p "$ROOT/dist"
for flavour in chromium firefox; do
  (cd "$OUT/$flavour" && rm -f "$ROOT/dist/Swoop-Shield-$flavour-$VERSION.zip" && zip -qr "$ROOT/dist/Swoop-Shield-$flavour-$VERSION.zip" .)
done
echo "Browser extension: $OUT/{chromium,firefox,safari}"
ls -la "$ROOT"/dist/Swoop-Shield-*.zip
