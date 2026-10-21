#!/usr/bin/env python3
"""Builds the engine archive the app installs on first launch.

Downloads every component dist/engine-manifest.json names, checks each
against its SHA-256, lays them out as Libraries/ the way Highball's installer
does, and packs Libraries.tar.gz plus the WhiskyWineVersion.plist that
advertises it.

Usage: scripts/assemble-engine.py <release-version> [workdir]
  release-version  the X.Y.Z of the release the archive is attached to: the
                   app downloads releases/download/v<X.Y.Z>/Libraries.tar.gz
  workdir          defaults to ~/Library/Application Support/com.furkan.kadeh/
                   engine-build, a folder antivirus is told to skip: Symantec
                   deletes some Wine DLLs the moment they are unpacked
                   anywhere else, and the archive would ship without them.
"""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFEST = REPO / "dist" / "engine-manifest.json"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(url, expected, downloads):
    target = downloads / url.rsplit("/", 1)[1]
    if not (target.exists() and sha256(target) == expected):
        subprocess.run(["curl", "-fL", "--retry", "3", "-o", target, url], check=True)
    actual = sha256(target)
    if actual != expected:
        sys.exit(f"error: {url}: sha256 {actual}, manifest says {expected}")
    return target


def place(source, dest):
    """A file replaces dest; a folder's contents are laid over dest."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        dest.mkdir(exist_ok=True)
        subprocess.run(["cp", "-a", f"{source}/.", dest], check=True)
    else:
        if dest.exists() or dest.is_symlink():
            dest.unlink()
        shutil.copy2(source, dest, follow_symlinks=False)


def check_links(root):
    """Tar.untar rejects an archive whose links leave the destination."""
    for link in (p for p in root.rglob("*") if p.is_symlink()):
        target = os.readlink(link)
        resolved = os.path.normpath(os.path.join(link.parent, target))
        if os.path.isabs(target) or not resolved.startswith(str(root) + os.sep):
            sys.exit(f"error: {link} -> {target} leaves Libraries")


def notices(manifest):
    lines = [
        "Third-party software in this engine",
        "",
        "Each component is unmodified from the download below, except where its",
        "note says how it was patched. Source for the LGPL parts is at the",
        "projects named in each URL. D3DMetal is Apple's, under the Game Porting",
        "Toolkit licence in renderers/d3dmetal/License.rtf: redistributed",
        "unmodified, for non-commercial use only. engine-manifest.json records",
        "every component's digest.",
        "",
    ]
    for name, c in manifest["components"].items():
        lines += [f"{name} {c.get('version', '')}".strip(), f"  licence: {c['license']}", f"  from: {c['url']}", ""]
    return "\n".join(lines)


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    version = sys.argv[1]
    major, minor, patch = (int(part) for part in version.split("."))
    default = Path.home() / "Library/Application Support/com.furkan.kadeh/engine-build"
    work = Path(sys.argv[2]) if len(sys.argv) == 3 else default
    downloads, unpacked, stage = work / "downloads", work / "unpacked", work / "stage"
    downloads.mkdir(parents=True, exist_ok=True)
    for folder in (unpacked, stage):
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir()
    libraries = stage / "Libraries"
    libraries.mkdir()

    manifest = json.loads(MANIFEST.read_text())
    # Patches and renderers (order 1) go over the engine and frameworks (order 0).
    components = sorted(manifest["components"].items(), key=lambda item: item[1].get("order", 0))
    for name, c in components:
        archive = fetch(c["url"], c["sha256"], downloads)
        rule = c.get("extract")
        if rule is None:
            place(archive, libraries / name)
            (libraries / name).chmod(0o755)
            continue
        # Two patches share one archive; unpack it once.
        folder = unpacked / archive.name
        if not folder.exists():
            folder.mkdir()
            subprocess.run(["tar", "-xf", archive, "-C", folder], check=True)
        source = folder / rule.get("subpath", rule.get("strip", ""))
        place(source, libraries / rule["into"])
        print(f"placed {name}")

    shutil.copy(MANIFEST, libraries / "engine-manifest.json")
    (libraries / "THIRD-PARTY-NOTICES.txt").write_text(notices(manifest))
    subprocess.run(["xattr", "-rc", libraries], check=True)
    check_links(libraries)
    if not (libraries / "engine/bin/wine").exists():
        sys.exit("error: no engine/bin/wine; the manifest layout changed")

    out = work / "Libraries.tar.gz"
    env = dict(os.environ, COPYFILE_DISABLE="1")
    subprocess.run(["tar", "--no-xattrs", "-czf", out, "-C", stage, "Libraries"], check=True, env=env)
    digest = sha256(out)
    plist = {"version": {"major": major, "minor": minor, "patch": patch}, "sha256": digest}
    with open(work / "WhiskyWineVersion.plist", "wb") as f:
        plistlib.dump(plist, f)
    files = sum(1 for p in libraries.rglob("*") if p.is_file())
    print(f"\n{out}\nsha256 {digest}\n{files} files\n{work / 'WhiskyWineVersion.plist'}")


if __name__ == "__main__":
    main()
