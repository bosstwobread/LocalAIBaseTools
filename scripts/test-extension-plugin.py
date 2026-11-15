#!/usr/bin/env python3
"""Build and verify an external native extension without installing it for the user."""
import argparse
import json
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "com.localaibasetools.example.external-greeting"


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=60, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path,
                        help="Optional built MacHelperApp executable for registry/settings integration.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Native MacHelper extension verification requires macOS and Xcode command-line tools.")
    if args.host and not args.host.is_file():
        parser.error("The specified MacHelperApp executable does not exist. Build the apps first.")

    with tempfile.TemporaryDirectory(prefix="mac-helper-external-extension-") as temporary:
        temporary = Path(temporary).resolve()
        assert not temporary.is_relative_to(ROOT.resolve()), "The independent build must live outside the repository."
        source = temporary / "external-author/ExternalGreeting"
        shutil.copytree(ROOT / "examples/ExternalGreeting", source,
                        ignore=shutil.ignore_patterns(".DS_Store", "__pycache__", ".build"))
        sdk = temporary / "public-sdk"
        sdk.mkdir()
        header = sdk / "MacHelperExtensionSDK.h"
        shutil.copy2(ROOT / "MacHelper/ExtensionSDK/Sources/MacHelperExtensionSDK/include/MacHelperExtensionSDK.h", header)
        plugins = temporary / "plugins"
        extension = plugins / "ExternalGreeting.machextension"
        run([sys.executable, str(source / "build.py"), "--sdk-header", str(header),
             "--output", str(extension)], cwd=source)
        print("PASS independent extension build outside the repository, using only the public SDK header")

        runner = temporary / "extension-runner"
        run(["xcrun", "clang", "-fobjc-arc", "-fmodules", "-framework", "Cocoa",
             "-mmacosx-version-min=14.0", "-I", str(sdk),
             str(source / "Tests/ExtensionRunner.m"), "-o", str(runner)], cwd=source)
        settings = temporary / "runner-settings"
        result = json.loads(run([str(runner), str(extension), str(settings)], cwd=temporary).stdout)
        assert result == {"factory": True, "lifecycle": True, "settingsView": True,
                          "persistence": True, "hostCallback": True}, result
        preference_file = settings / "greeting.json"
        assert json.loads(preference_file.read_text()) == {"count": 1}
        assert stat.S_IMODE(preference_file.stat().st_mode) == 0o600
        print("PASS native principal loading, start/stop, settings view, private preference persistence, and host callback")

        if args.host:
            output = run([str(args.host.resolve()), "--verify-extensions", "--extension-dir", str(plugins),
                          "--enable-test-extension", IDENTIFIER], cwd=temporary)
            report = json.loads(output.stdout)
            assert not report.get("issues"), report
            assert not report.get("errors"), report
            extension_report = next(entry for entry in report["extensions"] if entry["identifier"] == IDENTIFIER)
            assert extension_report["displayName"] == "External Greeting", extension_report
            assert extension_report["isBundled"] is False, extension_report
            assert extension_report["enabled"] is True, extension_report
            assert extension_report["running"] is True, extension_report
            assert extension_report["settingsLoaded"] is True, extension_report
            print("PASS MacHelper discovers, enables, starts, and embeds an independently built external extension")
        else:
            print("Host registry check skipped; add --host dist/MacHelper.app/Contents/MacOS/MacHelperApp after building MacHelper.")
    print("No user extension directory, preferences, AI service, or app permissions were changed.")


if __name__ == "__main__":
    main()
