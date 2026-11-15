#!/usr/bin/env python3
"""Build this extension independently using the public MacHelper SDK header."""
import argparse
import json
import plistlib
import shutil
import subprocess
from pathlib import Path

SOURCE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-header", type=Path, required=True,
                        help="Path to the public MacHelperExtensionSDK.h header.")
    parser.add_argument("--output", type=Path, default=Path.cwd() / "ExternalGreeting.machextension")
    parser.add_argument("--sign-identity", default="-", help="Code-signing identity; defaults to local ad-hoc signing.")
    args = parser.parse_args()
    if not args.sdk_header.is_file():
        parser.error("The public SDK header is missing.")
    destination = args.output.resolve()
    if destination.exists():
        parser.error("The output already exists. Choose a new output path.")
    manifest = json.loads((SOURCE / "extension.json").read_text())
    contents = destination / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    shutil.copy2(SOURCE / "extension.json", contents / "Resources/extension.json")
    executable = contents / "MacOS/ExternalGreetingExtension"
    subprocess.run([
        "xcrun", "clang", "-fobjc-arc", "-fmodules", "-bundle", "-framework", "Cocoa",
        "-mmacosx-version-min=14.0", "-I", str(args.sdk_header.resolve().parent),
        str(SOURCE / "Sources/ExternalGreetingExtension.m"), "-o", str(executable)
    ], check=True)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({
            "CFBundleIdentifier": manifest["identifier"],
            "CFBundleName": manifest["displayName"],
            "CFBundleExecutable": executable.name,
            "CFBundlePackageType": "BNDL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": manifest["version"],
            "CFBundleVersion": "1",
            "NSPrincipalClass": "ExternalGreetingExtension",
            "LSMinimumSystemVersion": "14.0"
        }, stream)
    subprocess.run(["codesign", "--force", "--sign", args.sign_identity,
                    "--identifier", manifest["identifier"], str(destination)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(destination)], check=True)
    print(destination)


if __name__ == "__main__":
    main()
