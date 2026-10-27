#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Builds Swoop.app and Swoop-<version>.dmg with only the Xcode Command Line Tools
# (xcode-select --install). No Xcode project, no Apple Developer account needed.
#
#   ./scripts/build-app.sh            # this Mac's architecture, ad-hoc signed
#   UNIVERSAL=1 ./scripts/build-app.sh
#   open dist/Swoop-0.2.0.dmg
#
# Swoop Shield adds to the bundle:
#   Contents/MacOS/swoop-resolver                                  local DNS fallback daemon
#   Contents/Library/SystemExtensions/com.swoopkey.swoop.shield.systemextension
#   Contents/PlugIns/SwoopShieldBlocker{1..6}.appex                Safari content blockers
#   Contents/PlugIns/SwoopShieldPageCleaner.appex                  Safari Web Extension
#   Contents/Resources/BrowserExtension/{chromium,firefox}         MV3 WebExtension
# The system extension only works when the build is signed with a Developer ID identity,
# APPLE_TEAM_ID is set and both Developer ID provisioning profiles are given
# (SHIELD_APP_PROFILE / SHIELD_EXT_PROFILE); see docs/SHIELD.md. Otherwise Shield runs in
# local-resolver / profile / browser modes.
#
# Environment:
#   SWOOP_VERSION=0.2.0     CFBundleShortVersionString and DMG name
#   UNIVERSAL=1             arm64 + x86_64 (lipo); CI always builds universal
#   SIGN_IDENTITY=-         "-" = ad-hoc (default). Releases: "Developer ID Application: <name> (<team>)"
#   NOTARY_PROFILE=         `xcrun notarytool store-credentials` profile: notarise + staple app and DMG
#   NOTARY_KEYCHAIN=        keychain holding that profile (CI uses a temporary one)
#   GOOGLE_CLIENT_ID=       optional default Google OAuth "Desktop app" client ID (users can set their own)
#   GOOGLE_CLIENT_SECRET=   optional, the matching (non-confidential) desktop client secret
#   APPLE_TEAM_ID=          10-character Team ID: App Group + XPC names for Shield (needed for Safari rules)
#   SHIELD_APP_PROFILE=     Developer ID provisioning profile for com.swoopkey.swoop (path or base64)
#   SHIELD_EXT_PROFILE=     Developer ID provisioning profile for com.swoopkey.swoop.shield (path or base64)
#   SHIELD_RULES=           optional swoop-shield-compile --out dir: bake full list rules into the browser extension
#   BUNDLE_ID=com.swoopkey.swoop
#   OUT_DIR=dist
set -euo pipefail

die() { echo "build-app: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[[ "$(uname -s)" == "Darwin" ]] || die "run this on macOS (it needs swift, codesign and hdiutil)"
for tool in swift codesign hdiutil plutil ditto; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found. Install the Command Line Tools: xcode-select --install"
done

VERSION="${SWOOP_VERSION:-0.2.0}"
UNIVERSAL="${UNIVERSAL:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
BUNDLE_ID="${BUNDLE_ID:-com.swoopkey.swoop}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
TEAM_ID="${APPLE_TEAM_ID:-}"
SHIELD_APP_PROFILE="${SHIELD_APP_PROFILE:-}"
SHIELD_EXT_PROFILE="${SHIELD_EXT_PROFILE:-}"
SHIELD_RULES="${SHIELD_RULES:-}"
EXT_ID="com.swoopkey.swoop.shield"
if [[ -n "$TEAM_ID" && ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then die "APPLE_TEAM_ID must be the 10-character Team ID"; fi
if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
  die "notarisation needs SIGN_IDENTITY=\"Developer ID Application: …\""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
APP="$OUT_DIR/Swoop.app"
DMG="$OUT_DIR/Swoop-$VERSION.dmg"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)"

staple() {
  local n
  for n in 1 2 3 4 5 6; do
    if xcrun stapler staple "$1"; then return 0; fi
    echo "   (stapling $(basename "$1") failed, attempt $n; retrying in $((n * 15))s)"
    sleep $((n * 15))
  done
  die "couldn't staple $(basename "$1")"
}
notarise() {
  local args=(--keychain-profile "$NOTARY_PROFILE")
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then args+=(--keychain "$NOTARY_KEYCHAIN"); fi
  local out; out="$(xcrun notarytool submit "$1" "${args[@]}" --wait --timeout 30m 2>&1)" || true
  echo "$out"
  if ! grep -q "status: Accepted" <<<"$out"; then
    local id; id="$(sed -n 's/^ *id: \([0-9a-f-]*\).*/\1/p' <<<"$out" | head -n 1)"
    if [[ -n "$id" ]]; then xcrun notarytool log "$id" "${args[@]}" || true; fi
    die "Apple did not accept $(basename "$1") for notarisation"
  fi
}

step "Building Swoop $VERSION (release)"
cd "$ROOT"
PRODUCTS=(Swoop swoop-resolver SwoopShieldExtension SwoopSafariBlocker SwoopSafariWebExtension)
BINDIR="$OUT_DIR/.bin"
rm -rf "$BINDIR" && mkdir -p "$BINDIR"
if [[ "$UNIVERSAL" == "1" ]]; then
  swift build -c release --triple arm64-apple-macosx13.0
  swift build -c release --triple x86_64-apple-macosx13.0
  ARM="$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)"
  X86="$(swift build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)"
  for p in "${PRODUCTS[@]}"; do lipo -create "$ARM/$p" "$X86/$p" -output "$BINDIR/$p"; done
  BIN_RESOURCES="$ARM"
else
  swift build -c release
  B="$(swift build -c release --show-bin-path)"
  for p in "${PRODUCTS[@]}"; do cp -X "$B/$p" "$BINDIR/$p"; done
  BIN_RESOURCES="$B"
fi
for p in "${PRODUCTS[@]}"; do [[ -x "$BINDIR/$p" ]] || die "build produced no executable for $p"; done
BIN="$BINDIR/Swoop"

step "Assembling Swoop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Examples"
cp -X "$BIN" "$APP/Contents/MacOS/Swoop"
chmod 755 "$APP/Contents/MacOS/Swoop"

ICON_KEY=""
if [[ -d "$ROOT/Resources/AppIcon.iconset" ]] && command -v iconutil >/dev/null \
   && iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  ICON_KEY="AppIcon"
elif [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then  # optional prebuilt fallback
  cp -X "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="AppIcon"
fi
echo "   app icon: ${ICON_KEY:-none}"

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Swoop</string>
  <key>CFBundleExecutable</key><string>Swoop</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Swoop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>${ICON_KEY}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppleEventsUsageDescription</key><string>Swoop uses System Events and Finder for commands you run: toggling dark mode, emptying the Trash, restarting, and managing login items.</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 DE NORONHA LTD. MIT Licence. swoopkey.com</string>
  <key>SwoopGoogleClientID</key><string>$(xml_escape "$GOOGLE_CLIENT_ID")</string>
  <key>SwoopGoogleClientSecret</key><string>$(xml_escape "$GOOGLE_CLIENT_SECRET")</string>
  <key>SwoopTeamID</key><string>${TEAM_ID}</string>
  <key>SwoopAppGroup</key><string>${TEAM_ID:+$TEAM_ID.com.swoopkey.swoop.shield}</string>
  <key>SwoopShieldMachService</key><string>${TEAM_ID:+$TEAM_ID.com.swoopkey.swoop.shield.xpc}</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -X "$ROOT/LICENSE" "$APP/Contents/Resources/"
cp -X "$ROOT"/examples/scripts/* "$APP/Contents/Resources/Examples/" 2>/dev/null || true
for b in "$BIN_RESOURCES"/*.bundle; do
  if [[ -e "$b" ]]; then ditto "$b" "$APP/Contents/Resources/$(basename "$b")"; fi
done

step "Assembling Swoop Shield"
cp -X "$BINDIR/swoop-resolver" "$APP/Contents/MacOS/swoop-resolver"
chmod 755 "$APP/Contents/MacOS/swoop-resolver"

plist_common() {   # $1 bundle id, $2 executable, $3 name, $4 package type
  cat <<P
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIdentifier</key><string>$1</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleName</key><string>$3</string>
  <key>CFBundleDisplayName</key><string>$3</string>
  <key>CFBundlePackageType</key><string>$4</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 DE NORONHA LTD. MIT Licence.</string>
  <key>SwoopTeamID</key><string>${TEAM_ID}</string>
  <key>SwoopAppGroup</key><string>${TEAM_ID:+$TEAM_ID.com.swoopkey.swoop.shield}</string>
P
}

# System extension (DNS proxy + content filter).
SYSX="$APP/Contents/Library/SystemExtensions/$EXT_ID.systemextension"
mkdir -p "$SYSX/Contents/MacOS"
cp -X "$BINDIR/SwoopShieldExtension" "$SYSX/Contents/MacOS/$EXT_ID"
cat > "$SYSX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$(plist_common "$EXT_ID" "$EXT_ID" "Swoop Shield" "SYSX")
  <key>NSSystemExtensionUsageDescription</key><string>Swoop Shield blocks ads, trackers and malware for every app on this Mac by filtering DNS on-device.</string>
  <key>NetworkExtension</key>
  <dict>
    <key>NEMachServiceName</key><string>${TEAM_ID:+$TEAM_ID.$EXT_ID.xpc}</string>
    <key>NEProviderClasses</key>
    <dict>
      <key>com.apple.networkextension.dns-proxy</key><string>DNSProxyProvider</string>
      <key>com.apple.networkextension.filter-data</key><string>FilterDataProvider</string>
    </dict>
  </dict>
</dict>
</plist>
PLIST
plutil -lint "$SYSX/Contents/Info.plist" >/dev/null

# Safari content blockers (same binary, one bundle per rule chunk) and the Safari Web Extension.
for n in 1 2 3 4 5 6; do
  AX="$APP/Contents/PlugIns/SwoopShieldBlocker$n.appex"
  mkdir -p "$AX/Contents/MacOS"
  cp -X "$BINDIR/SwoopSafariBlocker" "$AX/Contents/MacOS/SwoopSafariBlocker"
  cat > "$AX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$(plist_common "$BUNDLE_ID.safari.blocker$n" "SwoopSafariBlocker" "Swoop Shield $n" "XPC!")
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.Safari.content-blocker</string>
    <key>NSExtensionPrincipalClass</key><string>ContentBlockerRequestHandler</string>
  </dict>
</dict>
</plist>
PLIST
  plutil -lint "$AX/Contents/Info.plist" >/dev/null
done

if [[ -n "$SHIELD_RULES" ]]; then "$ROOT/scripts/build-webext.sh" "$SHIELD_RULES" >/dev/null; else "$ROOT/scripts/build-webext.sh" >/dev/null; fi
WX="$APP/Contents/PlugIns/SwoopShieldPageCleaner.appex"
mkdir -p "$WX/Contents/MacOS" "$WX/Contents/Resources"
cp -X "$BINDIR/SwoopSafariWebExtension" "$WX/Contents/MacOS/SwoopSafariWebExtension"
ditto "$ROOT/dist/webext/safari" "$WX/Contents/Resources"
cat > "$WX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$(plist_common "$BUNDLE_ID.safari.webext" "SwoopSafariWebExtension" "Swoop Shield Page Cleaner" "XPC!")
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string>
    <key>NSExtensionPrincipalClass</key><string>SafariWebExtensionHandler</string>
  </dict>
</dict>
</plist>
PLIST
plutil -lint "$WX/Contents/Info.plist" >/dev/null
mkdir -p "$APP/Contents/Resources/BrowserExtension"
ditto "$ROOT/dist/webext/chromium" "$APP/Contents/Resources/BrowserExtension/chromium"
ditto "$ROOT/dist/webext/firefox" "$APP/Contents/Resources/BrowserExtension/firefox"

# Entitlements: full Network Extension set only with Developer ID + Team ID + both profiles.
ENTDIR="$(mktemp -d)"
profile_to() {   # $1 value (path or base64), $2 destination
  if [[ -f "$1" ]]; then cp "$1" "$2"; else printf '%s' "$1" | tr -d '\r\n ' | base64 --decode > "$2"; fi
}
SHIELD_NE=0
if [[ "$SIGN_IDENTITY" != "-" && -n "$TEAM_ID" && -n "$SHIELD_APP_PROFILE" && -n "$SHIELD_EXT_PROFILE" ]]; then
  SHIELD_NE=1
  profile_to "$SHIELD_APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
  profile_to "$SHIELD_EXT_PROFILE" "$SYSX/Contents/embedded.provisionprofile"
  sed "s/__TEAM_ID__/$TEAM_ID/g" "$ROOT/Resources/Shield/Swoop.entitlements.template" > "$ENTDIR/app.entitlements"
  sed "s/__TEAM_ID__/$TEAM_ID/g" "$ROOT/Resources/Shield/ShieldExtension.entitlements.template" > "$ENTDIR/sysx.entitlements"
else
  cp "$ROOT/Resources/Swoop.entitlements" "$ENTDIR/app.entitlements"
  if [[ -n "$TEAM_ID" ]]; then
    # App Group (for Safari rules) without the restricted Network Extension entitlements.
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" \
      -c "Add :com.apple.security.application-groups:0 string $TEAM_ID.com.swoopkey.swoop.shield" "$ENTDIR/app.entitlements"
  fi
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>\n' > "$ENTDIR/sysx.entitlements"
fi
if [[ -n "$TEAM_ID" ]]; then
  sed "s/__TEAM_ID__/$TEAM_ID/g" "$ROOT/Resources/Shield/SafariExtension.entitlements.template" > "$ENTDIR/safari.entitlements"
else
  cp "$ROOT/Resources/Shield/SafariExtension-adhoc.entitlements" "$ENTDIR/safari.entitlements"
fi
for f in "$ENTDIR"/*.entitlements; do plutil -lint "$f" >/dev/null; done
echo "   system extension: $([[ $SHIELD_NE == 1 ]] && echo "enabled (Developer ID + Network Extension profiles)" || echo "bundled but not activatable (needs Developer ID, APPLE_TEAM_ID and both profiles)")"
echo "   Safari App Group: ${TEAM_ID:+$TEAM_ID.com.swoopkey.swoop.shield}${TEAM_ID:-none (no APPLE_TEAM_ID)}"

step "Signing (${SIGN_IDENTITY/#-/ad-hoc})"
xattr -cr "$APP"
plutil -lint "$ROOT/Resources/Swoop.entitlements" >/dev/null
sign() {   # $1 path, $2 entitlements (optional). Inside-out: nested code first.
  local args=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" == "-" ]]; then args+=(--timestamp=none); else args+=(--options runtime --timestamp); fi
  if [[ -n "${2:-}" ]]; then args+=(--entitlements "$2"); fi
  codesign "${args[@]}" "$1"
}
sign "$APP/Contents/MacOS/swoop-resolver" "$ROOT/Resources/Shield/Resolver.entitlements"
for ax in "$APP"/Contents/PlugIns/*.appex; do sign "$ax" "$ENTDIR/safari.entitlements"; done
sign "$SYSX" "$ENTDIR/sysx.entitlements"
sign "$APP" "$ENTDIR/app.entitlements"
rm -rf "$ENTDIR"
codesign --verify --deep --strict --verbose=2 "$APP"

NOTARISED=0
if [[ -n "$NOTARY_PROFILE" ]]; then
  step "Notarising Swoop.app"
  ZIP="$(mktemp -d)/Swoop-notarise.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  notarise "$ZIP"
  rm -rf "$(dirname "$ZIP")"
  staple "$APP"
  NOTARISED=1
fi

step "Creating $(basename "$DMG")"
STAGE="$(mktemp -d)/Swoop $VERSION"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Swoop.app"
ln -s /Applications "$STAGE/Applications"
if [[ "$NOTARISED" == "1" ]]; then
  OPEN_STEP="2. Open Swoop from Applications. It is signed and notarised by Apple."
else
  OPEN_STEP="2. This build isn't notarised. The first time, Control-click Swoop in Applications and
   choose Open. On macOS 15 or later: try to open it once, then go to System Settings >
   Privacy & Security and click \"Open Anyway\"."
fi
cat > "$STAGE/Read me first.txt" <<TXT
Swoop $VERSION — free, open-source launcher + Mac cleaner (MIT). swoopkey.com

1. Drag Swoop into Applications.
$OPEN_STEP
3. Press Option-Space to open Swoop (change it in the welcome screen or Settings).
4. Grant Accessibility when asked (window layouts, paste, snippets).
5. Swoop Shield (ad blocking): Settings > Shield. The system extension needs Swoop in
   Applications and one approval in System Settings; Safari's blockers are switched on in
   Safari > Settings > Extensions.
TXT
rm -f "$DMG"
hdiutil create -volname "Swoop $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
  step "Notarising $(basename "$DMG")"
  notarise "$DMG"
  staple "$DMG"
  spctl --assess --type execute -v "$APP"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
rm -rf "$(dirname "$STAGE")"
rm -rf "$BINDIR"

step "Done"
echo "App: $APP ($(du -sh "$APP" | cut -f1))"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
