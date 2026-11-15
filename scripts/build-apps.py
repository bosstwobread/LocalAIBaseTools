#!/usr/bin/env python3
"""Build MacHelper with generic capabilities and an editable Translation source catalog."""
import argparse
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def signing_identity(explicit=None):
    if explicit:
        return explicit
    result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True, check=True)
    matches = re.findall(r'([A-F0-9]{40}) "([^"]+)"', result.stdout)
    for prefix in ["Developer ID Application:", "Apple Development:"]:
        for fingerprint, name in matches:
            if name.startswith(prefix):
                return fingerprint
    return "-"


def sign(path, identity, identifier=None):
    command = ["codesign", "--force", "--sign", identity, "--timestamp=none"]
    if identifier:
        command += ["--identifier", identifier]
    subprocess.run(command + [str(path)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)


def build(package):
    subprocess.run(["swift", "build", "--package-path", str(package), "-c", "release"], check=True)
    result = subprocess.run(["swift", "build", "--package-path", str(package), "-c", "release", "--show-bin-path"], check=True, capture_output=True, text=True)
    return Path(result.stdout.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--signing-identity", help="Signing identity; otherwise prefer an existing Apple identity, falling back to ad hoc.")
    args = parser.parse_args()
    subprocess.run([sys.executable, str(ROOT / "scripts/build-app-icon.py")], check=True)
    identity = signing_identity(args.signing_identity)
    helper_bin = build(ROOT / "MacHelper")
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    legacy_artifact = dist / "Translation.app"
    if legacy_artifact.exists():
        shutil.rmtree(legacy_artifact)
    host = dist / "mac-helper-host"
    shutil.copy2(helper_bin / "mac-helper-host", host)
    sign(host, identity)
    app = dist / "MacHelper.app"
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    shutil.copy2(helper_bin / "MacHelperApp", contents / "MacOS/MacHelperApp")
    shutil.copy2(host, contents / "MacOS/mac-helper-host")
    metadata = {
        "CFBundleName": "MacHelper", "CFBundleDisplayName": "MacHelper",
        "CFBundleIdentifier": "com.localaibasetools.mac-helper", "CFBundleExecutable": "MacHelperApp",
        "CFBundlePackageType": "APPL", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleShortVersionString": "4.1.0", "CFBundleVersion": "411", "CFBundleIconFile": "AppIcon",
        "LSMinimumSystemVersion": "14.0", "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True, "LSUIElement": True,
        "NSHumanReadableCopyright": "© 2026 LocalAIBaseTools contributors. MIT License.",
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(metadata, stream)
    worker = contents / "MacOS/MacHelperScriptWorker"
    shutil.copy2(helper_bin / "MacHelperScriptWorker", worker)
    sign(worker, identity)
    resources = contents / "Resources"
    (resources / "SourceCatalog").mkdir(parents=True)
    shutil.copy2(ROOT / "MacHelper/Assets/AppIcon.icns", resources / "AppIcon.icns")
    shutil.copy2(ROOT / "catalog/extensions.json", resources / "SourceCatalog/extensions.json")
    shutil.copytree(ROOT / "Extensions/Translation", resources / "SourceSeeds/Translation",
                    ignore=shutil.ignore_patterns(".*", "__pycache__"))
    sign(app, identity, "com.localaibasetools.mac-helper")
    print(f"Built {app}")
    print("Translation source installs into its editable working folder when enabled; hot reload uses an independent worker.")


if __name__ == "__main__":
    main()
