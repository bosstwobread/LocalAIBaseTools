#!/usr/bin/env python3
"""Install the native host and Chrome/Edge manifests for the current user."""
import argparse
import json
import os
import re
import shutil
import tempfile
from pathlib import Path

HOST_NAME = "com.localaibasetools.mac_helper"
LEGACY_HOST_NAME = "com.messagehelper.gpt"
DEFAULT_EXTENSION_ID = "fmhfobfddchbeibojepeocgfemkpcklo"


def write_private_json(path, value):
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        temporary.chmod(0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extension-id", action="append", default=[], help="Authorize an additional Chrome/Edge extension ID; repeat for multiple tools.")
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / "dist/mac-helper-host")
    args = parser.parse_args()
    if any(not re.fullmatch(r"[a-p]{32}", value) for value in args.extension_id):
        parser.error("--extension-id must be a 32-character Chrome extension ID")
    if not args.binary.is_file():
        parser.error("Build the helper first with scripts/build-helper.sh")

    support = Path.home() / "Library/Application Support"
    destination = support / "LocalAIBaseTools/MacHelper"
    config = destination / "allowed-extension-ids.json"
    # Validate before changing the existing binary or any registration. On the
    # first migration, retain extra tool IDs authorized by the previous helper.
    previous_config = config if config.exists() else support / "MessageHelper/allowed-extension-ids.json"
    allowed_ids = {DEFAULT_EXTENSION_ID, *args.extension_id}
    if previous_config.is_file():
        try:
            previous = json.loads(previous_config.read_text())
        except (OSError, ValueError):
            parser.error("The existing native-host allowlist is invalid; review it before installing.")
        if not isinstance(previous, list) or any(not isinstance(value, str) or not re.fullmatch(r"[a-p]{32}", value) for value in previous):
            parser.error("The existing native-host allowlist is invalid; review it before installing.")
        allowed_ids.update(previous)
    destination.mkdir(parents=True, exist_ok=True)
    destination.chmod(0o700)
    installed_binary = destination / "mac-helper-host"
    # Replace the executable atomically so a connected browser can finish using
    # the old process safely. Reloading the extension starts the new executable.
    descriptor, temporary_name = tempfile.mkstemp(prefix=".mac-helper-host-", dir=destination)
    os.close(descriptor)
    temporary_binary = Path(temporary_name)
    try:
        shutil.copy2(args.binary, temporary_binary)
        temporary_binary.chmod(0o700)
        os.replace(temporary_binary, installed_binary)
    finally:
        temporary_binary.unlink(missing_ok=True)
    write_private_json(config, sorted(allowed_ids))
    manifest = {
        "name": HOST_NAME,
        "description": "LocalAIBaseTools MacHelper shared local AI bridge",
        "path": str(installed_binary),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{value}/" for value in sorted(allowed_ids)],
    }
    for relative in ["Google/Chrome/NativeMessagingHosts", "Microsoft Edge/NativeMessagingHosts"]:
        folder = support / relative
        folder.mkdir(parents=True, exist_ok=True)
        # Keep the old name as an alias so loaded MessageHelper versions can
        # reconnect during migration. Both names launch the same new executable.
        for name in [HOST_NAME, LEGACY_HOST_NAME]:
            path = folder / f"{name}.json"
            write_private_json(path, {**manifest, "name": name})
            print(f"Registered {path}")
    print(f"Installed {installed_binary}")

if __name__ == "__main__":
    main()
