# Signing and notarisation in CI

`.github/workflows/ci.yml` signs Swoop with a Developer ID Application certificate and notarises
it with Apple only when these repository secrets exist. Without them it builds an ad-hoc signed
DMG (fine for testing; Gatekeeper asks the user to approve it).

| Secret | What it holds |
| --- | --- |
| `MACOS_CERT_P12` | The Developer ID Application certificate + private key, exported as .p12 and base64-encoded |
| `MACOS_CERT_PASSWORD` | The .p12 export password |
| `APPLE_ID` | Apple ID email used for notarisation |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_APP_PASSWORD` | App-specific password for that Apple ID (appleid.apple.com › Sign-In and Security) |

Swoop Shield system extension (optional; without these Shield runs without it):

| Secret | What it holds |
| --- | --- |
| `SHIELD_APP_PROFILE` | Developer ID provisioning profile for `com.swoopkey.swoop` (System Extension + Network Extensions), base64 |
| `SHIELD_EXT_PROFILE` | Developer ID provisioning profile for `com.swoopkey.swoop.shield` (Network Extensions), base64 |

`APPLE_TEAM_ID` (above) also names Shield's App Group (`<TeamID>.com.swoopkey.swoop.shield`), which
the Safari content blockers need even without the profiles. How to create the App IDs and profiles:
[`SHIELD.md`](SHIELD.md#apple-developer-account-setup).

Optional:

| Secret | What it holds |
| --- | --- |
| `GOOGLE_CLIENT_ID` | Default Google OAuth *Desktop app* client ID baked into Info.plist |
| `GOOGLE_CLIENT_SECRET` | Its (non-confidential) desktop client secret |

The same five signing values the Pax repository uses work here unchanged (same Developer ID,
same team). GitHub secrets can't be read back or copied between repos, so they have to be
pasted again: Settings › Secrets and variables › Actions › New repository secret.

To export the certificate again if needed: Keychain Access › My Certificates › "Developer ID
Application: …" › Export (.p12), then `base64 -i cert.p12 | pbcopy`.
