# Releasing Mothership

`scripts/release.sh` builds the release app and signs every executable with the hardened
runtime (`scripts/Mothership.entitlements`). It notarizes and staples when credentials are
set, and writes `dist/Mothership-<version>.dmg`, which contains the app and an
/Applications link.

| Step | Status |
|---|---|
| Hardened runtime and entitlements | Done; verified that the hardened build launches and runs shells, the socket and the engine |
| DMG packaging | Done (`hdiutil verify` passes) |
| Developer ID signing | Needs a **Developer ID Application** certificate in the login keychain |
| Notarization and stapling | Needs a notarytool keychain profile (see below) |
| Auto-update (Sparkle) | Not wired yet. Needs a place to host the appcast and DMGs (e.g. GitHub Releases) and an EdDSA key |

## With a Developer ID

```sh
# once
xcrun notarytool store-credentials mothership \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

# every release
MOTHERSHIP_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
MOTHERSHIP_NOTARY_PROFILE=mothership \
scripts/release.sh
```

The script signs the inner binaries (`mship`, `mshipd`, …) and then the app. It verifies the
signature with `codesign --verify --strict --deep`, signs the DMG, submits it to the notary
service and waits, staples the ticket, and checks the result with `spctl`.
