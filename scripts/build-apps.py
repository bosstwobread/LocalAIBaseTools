#!/usr/bin/env python3
"""Build one MacHelper.app containing the independently built Translation extension."""
import argparse
import plistlib
import re
import shutil
import subprocess
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
    identity = signing_identity(args.signing_identity)
    helper_bin = build(ROOT / "MacHelper")
    translation_bin = build(ROOT / "Extensions/Translation")
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
        "CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "300",
        "LSMinimumSystemVersion": "14.0", "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True, "LSUIElement": True,
        "NSHumanReadableCopyright": "© 2026 LocalAIBaseTools contributors. MIT License.",
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(metadata, stream)
    plugin = contents / "PlugIns/Translation.machextension/Contents"
    (plugin / "MacOS").mkdir(parents=True)
    (plugin / "Resources").mkdir()
    shutil.copy2(translation_bin / "libTranslation.dylib", plugin / "MacOS/libTranslation.dylib")
    shutil.copy2(ROOT / "Extensions/Translation/extension.json", plugin / "Resources/extension.json")
    with (plugin / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleName": "Translation", "CFBundleIdentifier": "com.localaibasetools.translation",
                      "CFBundleExecutable": "libTranslation.dylib", "CFBundlePackageType": "BNDL",
                      "CFBundleShortVersionString": "2.1.0", "CFBundleVersion": "210",
                      "NSPrincipalClass": "TranslationExtension"}, stream)
    sign(plugin / "MacOS/libTranslation.dylib", identity)
    sign(plugin.parent, identity)
    sign(app, identity, "com.localaibasetools.mac-helper")
    print(f"Built {app}")
    print("Translation is bundled inside MacHelper; no separate Translation app is built or installed.")


if __name__ == "__main__":
    main()
