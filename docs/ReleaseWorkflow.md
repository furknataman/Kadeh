# Release Workflow

Kadeh releases are Developer ID signed, notarized DMGs published at
`https://github.com/furknataman/Kadeh/releases`. A release tag is `vX.Y.Z` and
must always include:

- `Kadeh-X.Y.Z.dmg`
- `appcast.xml`
- `WhiskyWineVersion.plist`

Include `Libraries.tar.gz` when the engine is rebuilt. The app reads the
appcast and engine plist from `releases/latest/download`, so neither metadata
file may be omitted from a release.

## One-time setup

Install a **Developer ID Application** certificate for team `PY8XQ9L8AA` in the
login keychain. Store the notarization credentials once in the keychain:

```sh
xcrun notarytool store-credentials kadeh-notary --key <path to .p8> --key-id <key id> --issuer <issuer id>
```

The release script uses `NOTARY_PROFILE`, which defaults to `kadeh-notary`.
Keys, key IDs, and issuer IDs must never be written into the repository, release
notes, the DMG, or GitHub.

Create the Sparkle EdDSA key under the account used by the release script:

```sh
~/Library/Developer/Xcode/DerivedData/Whisky-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account kadeh
```

The corresponding public key must match `SUPublicEDKey` in
`Whisky/Info.plist`. Back up the private key: losing it prevents existing
installations from accepting future updates.

## 1. Prepare the engine metadata

Rebuild the engine only when `dist/engine-manifest.json` changes:

```sh
scripts/assemble-engine.py X.Y.Z
```

The script downloads and SHA-256 verifies the manifest's components, assembles
the `Libraries/` layout, writes `THIRD-PARTY-NOTICES.txt` and the manifest into
the archive, and produces:

```text
~/Library/Application Support/com.furkan.kadeh/engine-build/Libraries.tar.gz
~/Library/Application Support/com.furkan.kadeh/engine-build/WhiskyWineVersion.plist
```

That build folder is excluded from antivirus scanning on the maintainer's Mac;
Symantec can otherwise delete Wine DLLs while the archive is assembled. The
plist contains the archive's SHA-256 and a version that names the GitHub tag
holding `Libraries.tar.gz`.

If the manifest has not changed, do not rebuild the engine. Reuse
`WhiskyWineVersion.plist` from the previous release unchanged. Its version must
continue to identify the earlier `vX.Y.Z` tag that holds the matching archive.

## 2. Build and sign the app release

Run:

```sh
scripts/release.sh X.Y.Z
```

The script derives a monotonically increasing Sparkle build number from the Git
commit count, archives `Kadeh.app`, exports it with Developer ID signing, and
creates `build/release/Kadeh-X.Y.Z.dmg`. The DMG contains `Kadeh.app` and an
Applications shortcut. It then signs the DMG with the Developer ID Application
identity for team `PY8XQ9L8AA`, notarizes it with the keychain profile, staples
and validates the ticket, and creates `build/release/appcast.xml` signed with
the Sparkle `kadeh` EdDSA key.

## 3. Publish the GitHub release

Use the engine plist prepared in step 1. When the engine was rebuilt for this
version, publish all four artifacts:

```sh
gh release create vX.Y.Z \
  --repo furknataman/Kadeh \
  --title "Kadeh X.Y.Z" \
  build/release/Kadeh-X.Y.Z.dmg \
  build/release/appcast.xml \
  "$HOME/Library/Application Support/com.furkan.kadeh/engine-build/WhiskyWineVersion.plist" \
  "$HOME/Library/Application Support/com.furkan.kadeh/engine-build/Libraries.tar.gz"
```

When the engine was not rebuilt, omit `Libraries.tar.gz` and upload the reused
plist instead:

```sh
gh release create vX.Y.Z \
  --repo furknataman/Kadeh \
  --title "Kadeh X.Y.Z" \
  build/release/Kadeh-X.Y.Z.dmg \
  build/release/appcast.xml \
  /path/to/previous/WhiskyWineVersion.plist
```

After publishing, confirm that the latest release exposes both metadata URLs:

- `https://github.com/furknataman/Kadeh/releases/latest/download/appcast.xml`
- `https://github.com/furknataman/Kadeh/releases/latest/download/WhiskyWineVersion.plist`

The plist's version must resolve to an existing archive at
`https://github.com/furknataman/Kadeh/releases/download/vX.Y.Z/Libraries.tar.gz`.

## Pitfalls

- `release.sh` must not override `CODE_SIGN_IDENTITY` at archive time. The
  project uses Manual signing with Apple Development; export re-signs with
  Developer ID.
- Do not bundle the `WhiskyKit` folder as Resources: notarization rejects its
  DocC plugin executables without hardened runtime. Keep the `PBXFileReference`
  and `PBXGroup` entries.
- In `Tar`, drain the pipe before calling `waitUntilExit()` to avoid a pipe
  deadlock.
