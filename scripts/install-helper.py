#!/usr/bin/env python3
"""Install the native host and Chrome/Edge manifests for the current user."""
import argparse
import json
import os
import re
import shutil
from pathlib import Path

HOST_NAME = "com.messagehelper.gpt"
DEFAULT_EXTENSION_ID = "fmhfobfddchbeibojepeocgfemkpcklo"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extension-id", default=DEFAULT_EXTENSION_ID)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / ".build/release/message-helper-host")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-p]{32}", args.extension_id):
        parser.error("--extension-id must be a 32-character Chrome extension ID")
    if not args.binary.is_file():
        parser.error("Build the helper first with scripts/build-helper.sh")

    support = Path.home() / "Library/Application Support"
    destination = support / "MessageHelper"
    destination.mkdir(parents=True, exist_ok=True)
    destination.chmod(0o700)
    installed_binary = destination / "message-helper-host"
    shutil.copy2(args.binary, installed_binary)
    installed_binary.chmod(0o700)
    config = destination / "allowed-extension-ids.json"
    config.write_text(json.dumps([args.extension_id]) + "\n")
    config.chmod(0o600)
    manifest = {
        "name": HOST_NAME,
        "description": "MessageHelper local GPT translation and English polishing",
        "path": str(installed_binary),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{args.extension_id}/"],
    }
    for relative in ["Google/Chrome/NativeMessagingHosts", "Microsoft Edge/NativeMessagingHosts"]:
        folder = support / relative
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{HOST_NAME}.json"
        temporary = folder / f".{HOST_NAME}.json.tmp"
        temporary.write_text(json.dumps(manifest, indent=2) + "\n")
        temporary.chmod(0o600)
        os.replace(temporary, path)
        print(f"Registered {path}")
    print(f"Installed {installed_binary}")

if __name__ == "__main__":
    main()
