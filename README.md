<div align="center">

  # Kadeh 🥃
  *Wine but a bit stronger*

  > Based on [frankea/Whisky](https://github.com/frankea/Whisky) and the original [whisky-app/whisky](https://github.com/whisky-app/whisky); not affiliated with getwhisky.app.

  ![](https://img.shields.io/github/actions/workflow/status/furknataman/Kadeh/CI.yml?style=for-the-badge&label=CI)
  [![](https://img.shields.io/github/downloads/furknataman/Kadeh/total?style=for-the-badge&logo=github&label=Downloads)](https://github.com/furknataman/Kadeh/releases)
  [![](https://img.shields.io/github/downloads/furknataman/Kadeh/latest/total?style=for-the-badge&label=Latest)](https://github.com/furknataman/Kadeh/releases/latest)
  [![](https://img.shields.io/github/issues/furknataman/Kadeh?style=for-the-badge)](https://github.com/furknataman/Kadeh/issues)
</div>

## Overview

Kadeh provides a clean and easy-to-use graphical wrapper for Wine built in native SwiftUI. You can make and manage bottles, install and run Windows apps and games, and unlock the full potential of your Mac with no technical knowledge required.

<img width="650" alt="Whisky in action" src="./images/demo.gif">

<img width="650" alt="Config" src="./images/config-screenshot.png">

*Familiar UI that integrates seamlessly with macOS*

<div align="right">
  <img width="650" alt="New Bottle" src="./images/new-bottle-screenshot.png">

  *One-click bottle creation and management*
</div>

<img width="650" alt="debug" src="./images/debug-screenshot.png">

*Debug and profile with ease*

---

## Key Features

- **Wine 10.0 (Sikarugir)** - An x86_64 Wine engine for Windows apps and games
- **DXMT & DXVK Graphics** - DirectX 11 through native Metal translation (DXMT) out of the box, with DXVK over MoltenVK as the universal fallback
- **Launcher Compatibility** - Built-in support for Steam, Epic, EA App, Rockstar, Battle.net, and more
- **Controller Support** - SDL environment variable controls for gamepad detection and mapping issues
- **Stability Diagnostics** - One-click diagnostic reports for troubleshooting crashes and freezes
- **Native SwiftUI** - Beautiful, familiar macOS interface

## System Requirements

- **CPU**: Apple Silicon (M-series chips)
- **OS**: macOS 27 or later
- **Rosetta 2**: Required by the x86_64 Wine engine; Kadeh offers to install it on first launch

## Installation

There is no Homebrew cask for Kadeh.

1. Download the latest **[Kadeh-X.Y.Z.dmg](https://github.com/furknataman/Kadeh/releases/latest)**.
2. Open the DMG and drag **Kadeh.app** onto the **Applications** shortcut.
3. Open Kadeh from **Applications**. The app and DMG are Developer ID signed and notarized, so Gatekeeper should accept them normally.
4. Complete first-launch setup. Kadeh offers to install Rosetta 2 if necessary, then downloads its engine (~465 MB download, ~1.2 GB on disk).

The engine contains Wine 10.0 (Sikarugir), D3DMetal 4.0 beta 2 from Apple's Game Porting Toolkit, DXMT, DXVK d9vk, and MoltenVK, as defined by Highball's [`dist/engine-manifest.json`](dist/engine-manifest.json). It is installed in `~/Library/Application Support/com.furkan.kadeh/Libraries`. Kadeh reads `releases/latest/download/WhiskyWineVersion.plist`, downloads `releases/download/vX.Y.Z/Libraries.tar.gz`, and checks the archive's SHA-256 before installation.

D3DMetal is redistributed unmodified under the Game Porting Toolkit licence, which permits non-commercial distribution only. Kadeh is GPL-3.0 software and must remain free. Wine and the other engine components use LGPL, MIT, zlib, or Apache licences; the engine includes `THIRD-PARTY-NOTICES.txt` and its manifest.

Some antivirus products, including Symantec Endpoint Protection, may delete Wine DLLs as false positives. If games fail after installation, exclude `~/Library/Application Support/com.furkan.kadeh` and `~/Library/Containers/com.furkan.kadeh`, then reinstall the engine.

In-app updates use Sparkle and `https://github.com/furknataman/Kadeh/releases/latest/download/appcast.xml`. Automatic update checks are off by default.

### Migrating from the original Whisky

Kadeh can reference bottles created by the archived original [whisky-app/whisky](https://github.com/whisky-app/whisky).

To switch:

1. Install Kadeh using the DMG above.
2. Open it and choose **File → Migrate from the Original Whisky…**. It finds the bottles the original app left in `~/Library/Containers/com.isaacmarovitz.Whisky/` and imports the ones you pick. Bottles are referenced **in place** — nothing is moved or copied — so the original app keeps working.
3. *(Optional)* Once you're happy, remove the original app: drag **/Applications/Whisky.app** to the Trash, or `brew uninstall --cask whisky` if you installed it via Homebrew. Your bottles stay put.

The original app uses a different bundle identifier (`com.furkan.kadeh` for Kadeh vs. `com.isaacmarovitz.Whisky`), which is why bottles are not shared automatically. The **Bottle → Export** / **File → Import Bottle** route also remains available for manual transfers.

## Uninstalling

Dragging **Kadeh.app** to the Trash removes the app but leaves the engine, your bottles, and app data behind.

> ⚠️ **Back up your bottles first if you want to keep them.** Removing `~/Library/Containers/com.furkan.kadeh` deletes every bottle under the default `Bottles` directory. Bottles you created in a custom folder live wherever you put them — check **Bottle → Reveal in Finder** before deleting anything.

To remove Kadeh **completely**, delete the app and then these paths:

```sh
# 1. The app itself
rm -rf "/Applications/Kadeh.app"

# 2. Bottles + bottle list (default bottle location is inside this container)
rm -rf ~/Library/Containers/com.furkan.kadeh
rm -rf ~/Library/Containers/com.furkan.kadeh.WhiskyThumbnail

# 3. The engine (~1.2 GB) and other app support
rm -rf ~/Library/Application\ Support/com.furkan.kadeh

# 4. Caches, logs, preferences, and saved state
rm -rf ~/Library/Caches/com.furkan.kadeh
rm -rf ~/Library/Logs/com.furkan.kadeh
rm -rf ~/Library/HTTPStorages/com.furkan.kadeh
rm -f  ~/Library/Preferences/com.furkan.kadeh.plist
```

If you also installed bottles in a **custom location**, delete those folders too. Migrated bottles that still belong to the original app live under `~/Library/Containers/com.isaacmarovitz.Whisky` and are left untouched by the steps above.

## Telemetry (opt-in)

Whisky sends **no data by default**. During first-run setup you can opt in to
anonymous usage telemetry — a checkbox that is **off** unless you tick it, and a
toggle you can change anytime in **Settings → Privacy**.

When (and only when) enabled, Whisky sends five events covering the first-run
funnel, so the maintainer can see where new installs fail:

| Event | Properties |
| --- | --- |
| `runtime_install_started` | — |
| `runtime_install_succeeded` | — |
| `runtime_install_failed` | `reason`: one of `download_failed`, `verify_failed`, `tarball_missing`, `extract_failed`, `runtime_incomplete` |
| `first_bottle_created` | — |
| `first_program_launch_attempted` | — |

`runtime_install_started` is sent once per setup attempt; the `_succeeded` /
`_failed` events are sent per install attempt (so retries are counted). The two
`first_…` events are sent at most once per install.

No personal data, file names, paths, raw error text, or identifiers tied to you
are ever sent. Events carry a random per-install anonymous ID (reset if you opt
out). Every event Whisky can send is the list above, and all of it is declared in
one file, [`Whisky/Utils/Telemetry.swift`](Whisky/Utils/Telemetry.swift), with
every automatic-capture feature of the analytics SDK disabled and no person
profile ever created (`identify()` is never called). Each event also carries the
SDK's standard context — app and macOS version, hardware model, locale, and more;
see [SECURITY.md](SECURITY.md) for the full list. Like any HTTPS request,
PostHog's ingestion sees the connecting IP (GeoIP enrichment is disabled); none
of this is tied to your identity.

## Documentation

- **[Support](docs/SUPPORT.md)** - Where to file bugs and what to expect from a single-maintainer fork
- **[Governance & continuity](docs/GOVERNANCE.md)** - Who maintains this and the honest bus-factor situation
- **[Runtime dependencies](docs/DEPENDENCIES.md)** - The bundled Wine/DXVK/D3DMetal/DXMT versions and their upstream sources

WhiskyKit, the core framework powering Whisky, has comprehensive API documentation:

- **[WhiskyKit API Documentation](https://frankea.github.io/Whisky/documentation/whiskykit/)** - Full API reference with usage examples
- **[Getting Started Guide](https://frankea.github.io/Whisky/documentation/whiskykit/gettingstarted)** - Learn how to integrate WhiskyKit
- **[Architecture Overview](https://frankea.github.io/Whisky/documentation/whiskykit/architecture)** - Understand how WhiskyKit components work together

### Troubleshooting

- **[Launcher Troubleshooting](docs/LauncherTroubleshooting.md)** - Fix issues with Steam, Epic, Battle.net, etc.
- **[Steam Compatibility Guide](docs/SteamCompatibility.md)** - Detailed guide for Steam on Whisky
- **[Stability Troubleshooting](docs/StabilityTroubleshooting.md)** - Diagnose crashes, freezes, reboots, and kernel panics
- **Controller Issues** - Enable "Controller Compatibility Mode" in Bottle Config → Controller & Input
- **[Game Configurations](https://github.com/frankea/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/GameDatabase/Resources/GameDB.json)** - 80+ curated per-game compatibility configs, also browsable in-app under Game Configurations

### Upstream issue audit

Per-issue accounting of how this fork addresses the open issues from the
archived upstream repo. Read [docs/AUDIT.md](docs/AUDIT.md) for the
methodology — including how to read the `addressed-direct` vs
`addressed-categorical` distinction and what `unverified` GameDB entries
actually mean.

### Test coverage

WhiskyKit unit tests cover the framework that holds the bottle, Wine, GameDB,
and PE-parser logic. See [`.github/workflows/CI.yml`](.github/workflows/CI.yml)
for the current CI configuration.

WhiskyUITests gives behavioural coverage of the SwiftUI surface (toolbar,
create-bottle sheet, and fixture-dependent flows).

---

## Credits & Acknowledgments

Whisky is possible thanks to the magic of several projects:

- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx and doitsujin
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) by Apple
- [CrossOver](https://www.codeweavers.com/crossover) by CodeWeavers and WineHQ
- D3DMetal by Apple

Special thanks to Gcenx, ohaiibuzzle, Nat Brown, and [Isaac Marovitz](https://github.com/IsaacMarovitz) (original author) for their support and contributions!

---

<table>
  <tr>
    <td>
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="./images/cw-dark.png">
          <img src="./images/cw-light.png" width="500">
        </picture>
    </td>
    <td>
        Whisky doesn't exist without CrossOver. If you want a fully-supported commercial Wine experience on macOS, check out <a href="https://www.codeweavers.com/crossover">CrossOver</a> from CodeWeavers. (This fork has no affiliate arrangement and receives nothing from CrossOver sales.)
    </td>
  </tr>
</table>
