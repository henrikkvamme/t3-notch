# Releasing

Pushing a version tag builds, signs, notarizes and publishes T3 Notch:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs [`scripts/release.sh`](scripts/release.sh) on a
`macos-26` runner. It builds an Apple silicon (arm64) app, stamps the tag's version into `Info.plist`, signs
it with Developer ID and the hardened runtime, notarizes and staples it, and attaches these to a GitHub Release:

- `T3-Notch-<version>.dmg`: the download. It holds the app and a link to Applications on a drawn background.
  The DMG itself is signed, notarized and stapled too.
- `T3-Notch.dmg`: the same DMG under a fixed name, so
  `https://github.com/lille-morille/t3-notch/releases/latest/download/T3-Notch.dmg` always gets the newest one.
- `T3-Notch-<version>.zip`: the app alone. Installed copies download it to update themselves
  (`Updater.swift` takes the first `.zip` asset).
- A `.sha256` file for the versioned DMG and the zip.

Installed copies see the release within six hours, or at their next launch, and offer the update.

## The DMG

[`scripts/make-dmg.sh`](scripts/make-dmg.sh) makes it with [dmgbuild](https://github.com/dmgbuild/dmgbuild),
which writes the Finder layout without Finder, so it also works on a runner with no GUI session. It installs
dmgbuild from [`scripts/dmg-requirements.txt`](scripts/dmg-requirements.txt) (pinned by hash) into a
temporary venv, so it needs Python 3.10 or later. The image is APFS with LZFSE compression (`ULFO`).

- The layout is in [`scripts/dmg-settings.py`](scripts/dmg-settings.py): a 660 × 400 pt window, 128 pt icons,
  the app at (180, 196) and Applications at (480, 196). The volume icon is the app icon.
- The background is drawn in code by [`scripts/dmg-background.swift`](scripts/dmg-background.swift). After you
  change it, run `swift scripts/dmg-background.swift Resources` and commit both PNGs (1x and 2x). dmgbuild
  joins them into one Retina TIFF. Keep its arrow and the icon positions in step.
- To check the layout without a certificate: `scripts/release.sh 0.0.0` (it signs ad hoc and skips the
  notary steps), then `open dist/T3-Notch-0.0.0.dmg`.

## One-time setup

The workflow needs five repository secrets (**Settings › Secrets and variables › Actions**).

1. **Developer ID certificate.** In Xcode: **Settings › Accounts**, pick the team, **Manage Certificates…**,
   **+ › Developer ID Application**. (Only the account holder can create one.)
2. **Export it.** In Keychain Access, under **My Certificates**, right-click
   *Developer ID Application: …* › **Export…** as a `.p12` with a password.
3. **Notary API key.** In App Store Connect: **Users and Access › Integrations › App Store Connect API › Team
   Keys**, **+**, access **Developer**. Download the `.p8` (it downloads only once) and note its **Key ID** and
   the **Issuer ID** shown above the list.
4. **Add the secrets:**

   ```sh
   gh secret set DEVELOPER_ID_P12_BASE64 --body "$(base64 -i DeveloperID.p12)"
   gh secret set DEVELOPER_ID_P12_PASSWORD          # paste the .p12 password
   gh secret set NOTARY_KEY_P8_BASE64 --body "$(base64 -i AuthKey_XXXXXXXXXX.p8)"
   gh secret set NOTARY_KEY_ID --body "XXXXXXXXXX"
   gh secret set NOTARY_ISSUER_ID --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```

To build a signed release locally, with the certificate in your keychain:
`NOTARY_KEY_PATH=AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… scripts/release.sh 0.2.0`.
