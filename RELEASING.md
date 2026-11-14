# Releasing

Pushing a version tag builds, signs, notarizes and publishes T3 Notch:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs [`scripts/release.sh`](scripts/release.sh) on a
`macos-26` runner. It builds a universal app (arm64 + x86_64), stamps the tag's version into `Info.plist`, signs
it with Developer ID and the hardened runtime, notarizes and staples it, and attaches `T3-Notch-<version>.zip`
(plus its SHA-256) to a GitHub Release. Installed copies see the release within six hours, or at their next
launch, and offer the update.

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

To build a release locally, with the certificate in your keychain:
`NOTARY_KEY_PATH=AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… scripts/release.sh 0.2.0`.
