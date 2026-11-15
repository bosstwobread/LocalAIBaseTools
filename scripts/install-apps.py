#!/usr/bin/env python3
"""Install the unified MacHelper app and shared browser native host for the current user."""
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def legacy_translation_processes(executable):
    """Match only this user's exact old executable, never a name substring."""
    output = subprocess.run(["ps", "-axo", "pid=,uid=,comm="], check=True,
                            capture_output=True, text=True).stdout
    matches = []
    for line in output.splitlines():
        parts = line.strip().split(maxsplit=2)
        if len(parts) != 3:
            continue
        try:
            pid, uid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        if uid == os.getuid() and pid > 1 and pid != os.getpid() and parts[2] == str(executable):
            matches.append(pid)
    return matches


def stop_legacy_translation(executable):
    pids = legacy_translation_processes(executable)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if not pids:
        return
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if not legacy_translation_processes(executable):
            return
        time.sleep(0.05)
    raise RuntimeError("The old Translation app did not quit. Quit it before running the installer again.")


def retire_legacy_translation(home):
    """Move our former standalone app to Trash; leave preferences intact."""
    legacy = home / "Applications/LocalAIBaseTools/Translation.app"
    if legacy.is_symlink() or not legacy.is_dir():
        return None
    try:
        with (legacy / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None
    executable = legacy / "Contents/MacOS/Translation"
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != "com.localaibasetools.translation" or \
            info.get("CFBundleExecutable") != "Translation" or not executable.is_file():
        return None
    stop_legacy_translation(executable)
    trash = home / ".Trash"
    trash.mkdir(mode=0o700, exist_ok=True)
    destination = trash / "Translation.app"
    suffix = 1
    while destination.exists() or destination.is_symlink():
        destination = trash / f"Translation (MacHelper migration {suffix}).app"
        suffix += 1
    legacy.rename(destination)
    return destination


def main():
    apps = [ROOT / "dist/MacHelper.app"]
    if any(not app.is_dir() for app in apps):
        raise SystemExit("Build MacHelper first with: python3 scripts/build-apps.py")
    subprocess.run([sys.executable, str(ROOT / "scripts/install-helper.py")], check=True)
    destination = Path.home() / "Applications/LocalAIBaseTools"
    destination.mkdir(parents=True, exist_ok=True)
    for source in apps:
        # Stage each complete bundle before replacing an earlier installation.
        with tempfile.TemporaryDirectory(prefix=".install-", dir=destination) as staging:
            staged = Path(staging) / source.name
            shutil.copytree(source, staged, symlinks=True)
            target = destination / source.name
            previous = Path(staging) / "previous.app"
            if target.exists():
                target.rename(previous)
            try:
                staged.rename(target)
            except BaseException:
                if previous.exists():
                    previous.rename(target)
                raise
        print(f"Installed {target}")
    retired = retire_legacy_translation(Path.home())
    if retired:
        print(f"Moved the old standalone Translation app to {retired}; its preferences were preserved.")
    print("Open MacHelper.app. Translation settings are under Extensions; launch at login is under General.")
    print("MacHelper requires your approval in System Settings > Privacy & Security > Accessibility for text selection.")
    print("If MacHelper is already running, quit and reopen it to use this build. Reload browser extensions to reconnect the host.")


if __name__ == "__main__":
    main()
