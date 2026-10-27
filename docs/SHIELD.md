# Swoop Shield

Swoop Shield is Swoop's built-in ad, tracker and malware blocker. It works at two levels:

1. **System-wide (DNS):** every app and browser on the Mac. Ad, tracking, telemetry and malware
   hostnames from the filter lists get "no such domain" back, so they never load.
2. **In the browser:** Safari content blockers plus a Safari Web Extension, and a Manifest V3
   WebExtension for Chrome, Arc, Brave, Edge, Vivaldi, Opera and Firefox. These hide ad elements,
   run scriptlets and block ad requests by URL. That covers ads served from the same domain as the
   page (YouTube, sponsored posts), which DNS can't touch.

Everything runs on the Mac. The lists come straight from their maintainers. The query log never
leaves the machine, and Shield sends no telemetry.

## How it fits together

```
                ┌────────────── Swoop.app (user) ───────────────┐
 filter lists → │ ShieldListManager: download → verify → compile │
 (maintainers)  │   shield.swsh (DNS index) · Safari JSON · DNR   │
                │ ShieldController: modes, pauses, allowlist,     │
                │   stats, launcher commands, menu bar counter    │
                └──────┬───────────────┬───────────────┬─────────┘
               XPC     │       files   │       App Group│
     ┌─────────────────▼──┐  ┌─────────▼────────┐  ┌────▼──────────────────────┐
     │ System extension   │  │ swoop-resolver   │  │ Safari content blockers ×6 │
     │ com.swoopkey.swoop │  │ (fallback)       │  │ Safari Web Extension       │
     │ .shield            │  │ LaunchDaemon,    │  └────────────────────────────┘
     │  NEDNSProxyProvider│  │ 127.0.0.1:53     │   Chrome / Firefox extension
     │  NEFilterData-     │  │ UDP + TCP        │   (loaded unpacked from
     │   Provider         │  └──────────────────┘    ~/Library/Application Support/
     └────────────────────┘                          Swoop/Shield/BrowserExtension)
```

All filtering decisions come from one engine, `Sources/ShieldCore` (Foundation + POSIX only, so it
builds and is unit-tested on Linux):

| Piece | File |
| --- | --- |
| Rule parser for Adblock Plus, uBlock Origin, AdGuard and hosts syntax, cosmetic rules and scriptlets | `RuleParser.swift`, `FilterRule.swift` |
| Compact binary index: a reversed-label trie in a flat 16-byte-per-node array, a deduplicated label pool, a Bloom filter for fast misses, and a side table for wildcard/regex/`$denyallow`/`$dnstype` rules. SHA-256 checked, memory-mapped | `DomainIndex.swift`, `BloomFilter.swift`, `SHA256.swift` |
| Matcher with precedence: allowlist > custom exceptions > custom blocks > `$important` exception > `$important` block > exception > block | `DomainMatcher.swift` |
| CNAME / HTTPS-alias uncloaking | `CNAMEUncloaker.swift` |
| Encrypted-DNS bypass policy (DoH/DoT/DoQ) | `EncryptedDNSPolicy.swift` |
| DNS wire format (parse, blocked answers with Extended DNS Error 15) | `DNSMessage.swift` |
| Safari content-blocker conversion and splitting | `SafariConverter.swift` |
| declarativeNetRequest + cosmetic bundle | `BrowserRuleCompiler.swift` |
| Download checks (size, format, title, minimum rules, max 50 % drop, optional signed manifest) | `ListIntegrity.swift` |
| Engine: config, pauses, decisions, stats, query log | `ShieldEngine.swift` |
| Local resolver (UDP + TCP, plain or DoH upstream) | `LocalResolver.swift` |

On the default lists (about 475,000 domains) the index takes around 15 MB, loads in a few
milliseconds without checksum verification (about 0.1 s with it), and a lookup averages a few
microseconds.

## Protection modes

| Mode | What it covers | Needs |
| --- | --- | --- |
| **System extension** (default) | DNS from every app (UDP and TCP), CNAME uncloaking, blocks DoH/DoT/DoQ bypass flows, blocks connections to blocked hostnames, per-app pause | Developer ID build with the Network Extension entitlement and both provisioning profiles; Swoop in /Applications; one approval in System Settings |
| **Local resolver** | Same lists, allowlist, custom rules, CNAME uncloaking, stats and log. Bypass blocking works through the resolver-name and canary policy only (there's no socket filter) | Admin password once. Installs `/Library/LaunchDaemons/com.swoopkey.swoop.resolver.plist`, which runs as the user; launchd binds 127.0.0.1:53 and [::1]:53. Sets every network service's DNS to 127.0.0.1 and saves the old settings, which turning Shield off restores |
| **Encrypted DNS profile** | A public ad-blocking DoH server (AdGuard DNS, Mullvad, Quad9) through a `com.apple.dnsSettings.managed` profile | Installing the profile. *Not on-device*: the provider's lists apply, not Swoop's, and there are no stats |
| **Browsers only** | Safari plus Chrome/Firefox extensions | Nothing |

### Encrypted DNS (DoH / DoT / DoQ)

- `use-application-dns.net` returns NXDOMAIN, which turns off Firefox's automatic DoH.
- Well-known public DoH hostnames return NXDOMAIN. Browsers then fall back to the system resolver,
  which Shield filters. Chrome, Edge and Brave only "auto-upgrade" to DoH when the system resolver
  is itself a known DoH provider, which Shield isn't.
- In system extension mode, the content filter also drops TCP/UDP 853 (DoT/DoQ) and 443/8443
  flows to the anycast IPs of the big public resolvers, except Shield's own configured upstream.
- Optional: `mask.icloud.com` and `mask-h2.icloud.com` return NXDOMAIN. This is Apple's
  documented network opt-out for iCloud Private Relay, so Safari's DNS stays filtered. macOS shows
  a notice when this happens. It's off by default.
- A user-configured DoH server inside an app or browser, at an unknown address, can still get
  around the DNS layer. The browser extensions still apply in that case.

### CNAME cloaking

After the upstream answers, Shield checks every name in the CNAME chain and in the HTTPS/SVCB
TargetName against the same rules. If any of them is blocked, the original lookup is answered as
blocked. An explicit allow for the original name always wins. Loops and chains longer than 16 are
cut off. A small built-in set of well-known cloaking networks (Eulerian, AT Internet, Adobe
`omtrdc`, Criteo `dnsdelegation`/`storetail`, Commanders Act, Mapp, …) is applied only when the
target belongs to a different site than the query. The full AdGuard cname-trackers list (MIT) is
an optional list.

## Using Swoop with Pax

[Pax](https://paxpeace.com) is an accountability / adult-content blocker for the Mac. Its
root service, pax-guard, owns the Mac's DNS (a filtering forwarder on 127.0.0.1:53 that the
network settings point at), adds `/etc/hosts` blocks and `pf` rules, installs a locked device
profile with browser policies, uses DNS over HTTPS to `dns.paxpeace.com` / `api.paxpeace.com`
with CleanBrowsing and AdGuard Family as fallbacks, and treats DNS changes, VPN-like or
DNS-proxy network extensions as tampering. Swoop is built to sit next to it without clashing.

**How Swoop recognises Pax** (any one is enough; read-only checks, re-run every minute and
whenever the Shield tab opens): `/Library/PaxGuard` exists; a pax-guard launchd job (plist in
`/Library/LaunchDaemons` or the process is running); the Pax app (`org.paxmobile.pax`,
`org.paxpeace.pax`, or an app signed by Pax's Team ID `Z94GSK7JA8`); the system resolver is
127.0.0.1 and pax-guard is installed or running; or Pax's profile is installed (`profiles`
output, or managed browser policies mentioning Pax). The decision logic is
`ShieldCore/PaxCompatibility.swift` (unit-tested); the app gathers the signals in
`Sources/Swoop/Shield/PaxDetector.swift`.

**What Shield does when Pax is present ("Works with Pax" mode)**

- It never installs or enables its DNS-proxy system extension, local resolver (so nothing else
  listens on port 53) or encrypted-DNS profile, and never changes network DNS settings,
  `/etc/hosts` or `pf`. If one of those was running before Pax arrived, Shield turns it off:
  the DNS proxy is disabled and swoop-resolver is removed **without** touching DNS settings
  (they belong to Pax); a Swoop DNS profile can't be removed by an app, so Shield asks you to
  remove it in System Settings.
- It never blocks Pax's servers or the resolvers Pax relies on (`paxpeace.com` and subdomains,
  `cleanbrowsing.org`, AdGuard Family, Quad9 and Cloudflare's malware-blocking resolvers, by
  name and address), and its own DNS-bypass blocking (DoH/DoT/DoQ, Firefox canary, Private
  Relay opt-out) is off. The built-in browser rules always allow `paxpeace.com`.
- It keeps blocking ads in Safari (content blockers + web extension) and in Chrome/Firefox
  (the browser extension). Signed builds can also run the content filter, opt-in and drop-only:
  it can block connections to ad servers but can't allow or redirect anything Pax blocks.
- The Shield tab explains that Pax already filters DNS and suggests turning on Pax's **Ads**
  switch for system-wide ad blocking. If Pax is removed, Shield goes back to the mode you had.

**The cleaner treats Pax as protected** (`SwoopCore/PaxProtection.swift`): the Uninstaller,
leftover and junk scans, Login Items, Security Check, Quit All / Force Quit and every file
removal skip the Pax app, pax-guard, `/Library/PaxGuard`, its launch daemons and its profile
(shown as "Protected (Pax)", never flagged). Maintenance tasks never touch Pax, DNS settings,
`/etc/hosts` or `pf`; flushing the DNS cache is fine.

## Filter lists and licences

Swoop doesn't bundle or redistribute third-party lists. Each Mac downloads them from their
maintainers. The browser-extension zips built by CI do include compiled rules, and ship an
`ATTRIBUTION.md` naming each list, its version, SHA-256 and licence.

| List | Default | Layers | Licence |
| --- | --- | --- | --- |
| HaGeZi Multi PRO | on | DNS | GPL-3.0 |
| HaGeZi Multi NORMAL | off | DNS | GPL-3.0 |
| OISD big | on | DNS | GPL-3.0 |
| AdGuard DNS filter | on | DNS | GPL-3.0 |
| Peter Lowe's list | on | DNS + browsers | free to use, no formal licence ([policy](https://pgl.yoyo.org/adservers/policy.php)) |
| URLhaus (malware-filter) | on | DNS | CC0-1.0 data / MIT scripts |
| EasyList | on | DNS (host rules) + browsers | GPL-3.0 or CC BY-SA 3.0 |
| EasyPrivacy | on | DNS (host rules) + browsers | GPL-3.0 or CC BY-SA 3.0 |
| HaGeZi native tracker: Microsoft | off | DNS | GPL-3.0 |
| HaGeZi native tracker: Apple | off | DNS | GPL-3.0 |
| AdGuard CNAME-cloaked trackers | off | DNS | MIT |

Updates: lists are checked hourly and each one is refreshed about once a day. A list's own
`! Expires:` is followed when it's shorter, but never more often than every 6 hours. Every
download goes through the same checks: allowed host (redirects included), size limits, not an
HTML/captive-portal page, expected `! Title:`, minimum rule count, and no drop of more than 50 %
against the previous copy. The SHA-256 is recorded. A failed update keeps the last good copy.
Upstream lists aren't signed. `ListManifest` can enforce a Swoop-signed manifest that pins
snapshots by hash, but no signing key or manifest is published yet (see *Not done yet*).

## Browser layer

- **Safari:** six content-blocker extensions (`com.swoopkey.swoop.safari.blocker1…6`) read rule
  chunks from the App Group container. Safari allows 150,000 rules per blocker, but WebKit's
  compiler runs out of memory well before that, so Swoop spreads rules evenly with at most 50,000
  per blocker. Each chunk carries all exception rules after its block rules, because
  `ignore-previous-rules` only applies within a list. Procedural cosmetic rules and scriptlets are
  handled by the Safari Web Extension "Swoop Shield Page Cleaner" (`…safari.webext`).
- **Chromium and Firefox:** `Extensions/webext`, Manifest V3. Plain `||host^` rules are grouped into
  `requestDomains` rules of 1,000 hosts each, so all of EasyList, EasyPrivacy and Peter Lowe fit in
  about 19,000 rules, under Chrome's 30,000 guaranteed static rules. Content scripts do lazy
  generic hiding (a `.class`/`#id` selector is only injected when that class or id shows up in the
  page), site-specific CSS, and procedural selectors (`:has-text`, `:upward`, `:remove`,
  `:matches-css`, `:min-text-length`, `:-abp-has`, `:xpath`). Scriptlets are injected into the
  page's MAIN world on navigation commit. Per-site pause uses an `allowAllRequests` dynamic rule.
- **YouTube** (best effort): the scriptlets remove `adPlacements`, `playerAds` and `adSlots` from
  the player data (`JSON.parse`, `fetch` and XHR responses), cosmetic rules hide ad slots, and a
  fallback mutes an ad that still starts, jumps to its end and presses Skip. YouTube changes often,
  so expect gaps.
- In the app, Swoop copies the extension to
  `~/Library/Application Support/Swoop/Shield/BrowserExtension/{chromium,firefox}` and fills in the
  Mac's freshly compiled rules. Load it unpacked. After a list update, click Reload on the browser's
  extensions page. A Chrome Web Store or AMO listing would update on its own; neither is published.

## UI, commands and hotkeys

- **Settings › Shield:** an Overview tab (on/off, mode, live counters, top blocked domains and apps,
  pause for 5 min / 15 min / 1 h / until tomorrow, per-app and per-site pauses), Query Log
  (searchable, local only, 1 h / 24 h / 7 days, right-click to allow or block), Filter Lists
  (toggles, licences, rule counts, errors, Update), My Rules (allowlist and custom rules in
  Adblock/hosts syntax with per-line validation), Browsers (setup) and Advanced (block response,
  CNAME settings, encrypted DNS, Private Relay, upstream, menu bar counter, reset, uninstall
  extension).
- **Launcher commands** (each can get a hotkey in Settings › Hotkeys › Shield): Toggle Swoop Shield,
  Pause Ads for 5 Minutes, Pause Ads for 1 Hour, Resume Ad Blocking, Allow This Site (reads the
  front tab's URL from Safari and Chromium browsers and asks for Firefox), Pause Ads on This Site
  for 1 Hour, Block a Domain, Shield Stats, Open Swoop Shield, Update Filter Lists.
- **Menu bar:** `⛨ 1.2k` (blocked today; `⏸` while paused), plus Shield items in the menu.

## Apple Developer account setup

The system extension needs a Developer ID build carrying the Network Extension entitlements. That
means two explicit App IDs and two Developer ID provisioning profiles. Without them, Swoop still
builds and runs, and Shield offers Local resolver, Profile and Browsers modes.

1. **Identifiers** (developer.apple.com › Certificates, IDs & Profiles › Identifiers › +, App IDs):
   - `com.swoopkey.swoop` (explicit). Capabilities: **System Extension**, **Network Extensions**,
     and optionally **App Groups**.
   - `com.swoopkey.swoop.shield` (explicit). Capabilities: **Network Extensions**, and optionally
     **App Groups**.
   - The Safari extension IDs (`com.swoopkey.swoop.safari.blocker1`–`6`,
     `com.swoopkey.swoop.safari.webext`) need no capabilities. The App Group Swoop uses is
     `<TeamID>.com.swoopkey.swoop.shield`. Team-prefixed groups don't need registering for
     Developer ID on macOS.
2. **Profiles** (Profiles › +): **Developer ID** (under Distribution).
   - Choose `com.swoopkey.swoop`, then the Developer ID Application certificate. Name it
     "Swoop Developer ID". Download it.
   - Repeat for `com.swoopkey.swoop.shield` and name it "Swoop Shield Developer ID".
   - If the portal asks which Network Extension types to include, pick **DNS Proxy** and
     **Content Filter**. Developer ID uses the `-systemextension` variants:
     `dns-proxy-systemextension` and `content-filter-provider-systemextension`.
3. **GitHub secrets** (repo Settings › Secrets and variables › Actions):
   - `SHIELD_APP_PROFILE`: `base64 -i "Swoop_Developer_ID.provisionprofile" | pbcopy`
   - `SHIELD_EXT_PROFILE`: `base64 -i "Swoop_Shield_Developer_ID.provisionprofile" | pbcopy`
   - `APPLE_TEAM_ID` (already listed for notarisation). It also names the App Group and the
     extension's XPC service.
4. **Local build:**
   `SIGN_IDENTITY="Developer ID Application: … (TEAMID)" APPLE_TEAM_ID=TEAMID SHIELD_APP_PROFILE=~/Downloads/Swoop_Developer_ID.provisionprofile SHIELD_EXT_PROFILE=~/Downloads/Swoop_Shield_Developer_ID.provisionprofile NOTARY_PROFILE=… UNIVERSAL=1 ./scripts/build-app.sh`
5. **First run on a Mac:**
   - Move Swoop to /Applications. System extensions only activate from there.
   - Open Settings › Shield and turn it on.
   - Approve Swoop in System Settings › General › Login Items & Extensions › Network Extensions
     (macOS 15+), or in Privacy & Security on macOS 13–14.
   - Accept the "Swoop would like to add proxy configurations" and "filter network content"
     prompts.
   - Check with `systemextensionsctl list` and System Settings › Network › Filters.

Entitlements by build type (`scripts/build-app.sh` picks automatically):

| Build | App | System extension | Safari extensions |
| --- | --- | --- | --- |
| ad-hoc (no Team ID) | apple-events | bundled, sandbox only (can't be activated) | sandbox, no App Group, so Safari gets no rules |
| Developer ID + `APPLE_TEAM_ID`, no profiles | apple-events + App Group | bundled, sandbox only | sandbox + App Group (Safari works) |
| Developer ID + Team ID + both profiles | apple-events, `system-extension.install`, `networking.networkextension` (dns-proxy-systemextension, content-filter-provider-systemextension), App Group, application-identifier, team-identifier, embedded profile | sandbox, network client/server, the same NE values, App Group, embedded profile | sandbox + App Group |

## Not done yet, and what's best effort

- Shield's macOS code (system extension, Safari extensions, UI) is written against the SDK
  documentation but hasn't been compiled or run on a Mac yet. CI on macOS is the first compile. The
  engine, resolver, converters and scriptlets are compiled and tested on Linux.
- Per-app pause relies on macOS telling the DNS proxy which app made a lookup
  (`sourceAppSigningIdentifier`) and the filter which app opened a connection. Lookups that macOS
  answers from its own cache or attributes to the system can't be paused per app.
- A site pause at the DNS layer lets the site's own domain through for every app. A true
  "everything on this page" pause exists only in the browser extensions.
- The Chrome and Firefox extensions aren't on the Chrome Web Store or AMO, so they install unpacked
  (Chromium) or as temporary add-ons (Firefox).
- Signed list manifest: `ListManifest` verification exists, but no CI job signs one and no public
  key is pinned in the app.
- iCloud Private Relay, Chrome's "Secure DNS" set to a custom provider, and VPN apps that bring
  their own DNS can take precedence over Shield's DNS layer. The browser extensions still apply.
