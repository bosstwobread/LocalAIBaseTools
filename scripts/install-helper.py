#!/usr/bin/env python3
"""Install the native host and Chrome/Edge manifests for the current user."""
import argparse
import json
import os
import re
import shutil
import stat
import tempfile
from pathlib import Path

HOST_NAME = "com.localaibasetools.mac_helper"
LEGACY_HOST_NAME = "com.messagehelper.gpt"
DEFAULT_EXTENSION_ID = "fmhfobfddchbeibojepeocgfemkpcklo"
CONNECTOR_EXTENSION_ID = "kkmffpbghoojlnldpdolonpjmkhdenkh"
DEFAULT_EXTENSION_IDS = [DEFAULT_EXTENSION_ID, CONNECTOR_EXTENSION_ID]
DISCOVERY_SIDECARS = {"discovery-config.json": 64 * 1024,
                      "discovery-index.json": 16 * 1024 * 1024,
                      "discovery-manifest.json": 64 * 1024}


def read_public_json(path, root, maximum, text=False):
    """Read only the named regular file through descriptor-relative traversal."""
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        pieces = path.relative_to(root).parts
        for piece in pieces[:-1]:
            next_directory = os.open(piece, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = next_directory
        descriptor = os.open(pieces[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            attributes = os.fstat(descriptor)
            if not stat.S_ISREG(attributes.st_mode) or attributes.st_size > maximum:
                raise ValueError(f"Discovery release file is not a bounded regular file: {path}")
            with os.fdopen(descriptor, "rb", closefd=False) as stream:
                data = stream.read(maximum + 1)
            valid = bool(data) and "\0" not in data.decode("utf-8") if text else isinstance(json.loads(data), dict)
            if len(data) > maximum or not valid:
                raise ValueError(f"Discovery release file must contain a bounded JSON object: {path}")
            return data
        finally:
            os.close(descriptor)
    except FileNotFoundError:
        return None
    finally:
        os.close(directory)


def discovery_sidecars(binary, destination):
    """Preflight public release seeds without following links or reading settings."""
    result = {}
    for name, maximum in DISCOVERY_SIDECARS.items():
        candidates = [binary.parent / name, binary.parent.parent / "Resources/Discovery" / name]
        for path in candidates:
            data = read_public_json(path, binary.parent.parent, maximum)
            if data is not None:
                result[name] = data
                break
        target = destination / name
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValueError(f"Discovery destination must be a regular file: {target}")
    prompts = destination / "DiscoveryPrompts"
    if prompts.is_symlink() or (prompts.exists() and not prompts.is_dir()):
        raise ValueError("Discovery prompt destination must be an ordinary directory")
    for name in ["rank.txt", "expand.txt"]:
        for path in [binary.parent / "DiscoveryPrompts" / name, binary.parent.parent / "Resources/DiscoveryPrompts" / name]:
            data = read_public_json(path, binary.parent.parent, 16 * 1024, text=True)
            if data is not None:
                result["DiscoveryPrompts/" + name] = data
                break
        target = prompts / name
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValueError("Discovery prompt destination must be an ordinary file")
    return result


def write_private_bytes(path, data):
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


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
    allowed_ids = {*DEFAULT_EXTENSION_IDS, *args.extension_id}
    if previous_config.is_file():
        try:
            previous = json.loads(previous_config.read_text())
        except (OSError, ValueError):
            parser.error("The existing native-host allowlist is invalid; review it before installing.")
        if not isinstance(previous, list) or any(not isinstance(value, str) or not re.fullmatch(r"[a-p]{32}", value) for value in previous):
            parser.error("The existing native-host allowlist is invalid; review it before installing.")
        allowed_ids.update(previous)
    try:
        sidecars = discovery_sidecars(args.binary.absolute(), destination)
    except (OSError, ValueError) as error:
        parser.error(f"The discovery release files are invalid; existing installation was preserved. {error}")
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
    for name, data in sidecars.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.parent != destination:
            target.parent.chmod(0o700)
        write_private_bytes(target, data)
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
