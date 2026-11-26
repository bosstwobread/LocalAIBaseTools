#!/usr/bin/env python3
"""Build MacHelper with the shared runtime, SDK, and discovery metadata."""
import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

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
    config_path = ROOT / "ExtensionMarket-website/marketplace.config.json"
    default_marketplace = json.loads(config_path.read_text())["baseUrl"] if config_path.exists() else "https://local-ai-extension.nelson007.com/"
    parser.add_argument("--marketplace-url", default=default_marketplace, help="Public HTTPS URL opened by MacHelper's Marketplace entry.")
    args = parser.parse_args()
    market_url = urlsplit(args.marketplace_url)
    if market_url.scheme != "https" or not market_url.hostname or market_url.username or market_url.password or market_url.query or market_url.fragment:
        parser.error("The marketplace URL must be a public HTTPS website URL without credentials, query, or fragment.")
    subprocess.run([sys.executable, str(ROOT / "scripts/build-app-icon.py")], check=True)
    dist = ROOT / "dist"
    identity = signing_identity(args.signing_identity)
    marketplace = ROOT / "ExtensionMarket-website"
    subprocess.run([sys.executable, str(marketplace / "discovery.py"),
                    "--registry", str(marketplace / "registry.json"), "--output", str(dist)], check=True)
    shutil.copytree(ROOT / "MacHelper/Runtime/DiscoveryPrompts", dist / "DiscoveryPrompts", dirs_exist_ok=True)
    (dist / "discovery-config.json").write_text(json.dumps({"schemaVersion": 1, "websiteURL": args.marketplace_url}) + "\n")
    helper_bin = build(ROOT / "MacHelper")
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
        "CFBundleShortVersionString": "6.9.1", "CFBundleVersion": "691", "CFBundleIconFile": "AppIcon",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": sorted(path.stem for path in (ROOT / "MacHelper/Runtime/Localization").glob("*.json")),
        "MacHelperMarketplaceURL": args.marketplace_url,
        "CFBundleURLTypes": [{"CFBundleURLName": "com.localaibasetools.marketplace", "CFBundleURLSchemes": ["machelper"], "CFBundleTypeRole": "Viewer"}],
        "LSMinimumSystemVersion": "14.0", "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True, "LSUIElement": False,
        "NSHumanReadableCopyright": "© 2026 LocalAIBaseTools contributors. MIT License.",
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(metadata, stream)
    worker = contents / "MacOS/MacHelperScriptWorker"
    shutil.copy2(helper_bin / "MacHelperScriptWorker", worker)
    sign(worker, identity)
    companion = contents / "MacOS/mac-helper-companion"
    shutil.copy2(helper_bin / "mac-helper-companion", companion)
    sign(companion, identity)
    resources = contents / "Resources"
    shutil.copytree(ROOT / "MacHelper/Runtime/Localization", resources / "Localization")
    shutil.copytree(ROOT / "MacHelper/Runtime/DiscoveryPrompts", resources / "DiscoveryPrompts")
    (resources / "Discovery").mkdir()
    for name in ["discovery-index.json", "discovery-manifest.json"]:
        shutil.copy2(dist / name, resources / "Discovery" / name)
    shutil.copy2(dist / "discovery-config.json", resources / "Discovery/discovery-config.json")
    # Explicit public documentation only; AI_DEPLOYMENT.md stays local.
    for relative in ["AI_EXTENSION_GUIDE.md", "docs/Extension-Development.md", "docs/Source-Extensions.md", "docs/Native-Extensions.md", "docs/MacHelper-Protocol.md"]:
        destination = resources / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    (resources / "NativeExtensionSDK").mkdir()
    shutil.copy2(ROOT / "MacHelper/NativeExtensionSDK/MacHelperNativeSDK.swift", resources / "NativeExtensionSDK/MacHelperNativeSDK.swift")
    shutil.copy2(ROOT / "MacHelper/Assets/AppIcon.icns", resources / "AppIcon.icns")
    sign(app, identity, "com.localaibasetools.mac-helper")
    print(f"Built {app}")


if __name__ == "__main__":
    main()
