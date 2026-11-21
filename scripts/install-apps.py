#!/usr/bin/env python3
"""Install the unified MacHelper app and shared browser native host for the current user."""
import fcntl
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


def processes_at(executable):
    """Match only this user's exact executable, never a name substring."""
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
    pids = processes_at(executable)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if not pids:
        return
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if not processes_at(executable):
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


MAC_HELPER_ID = "com.localaibasetools.mac-helper"
MAC_HELPER_EXECUTABLE = Path("Contents/MacOS/MacHelperApp")

# Use AppKit's ordinary quit request so the delegate can stop its workers and
# local service. Resolve the PID again inside AppKit before asking it to quit.
QUIT_INSTALLED_APP = """
ObjC.import('AppKit');
function run(argv) {
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]));
    if (app.isNil()) return;
    if (ObjC.unwrap(app.bundleIdentifier) !== argv[1] || ObjC.unwrap(app.executableURL.path) !== argv[2])
        throw new Error('The running application no longer matches the installed MacHelper.');
    if (!app.terminate) throw new Error('MacHelper declined the quit request.');
}
"""


def check_mac_helper(bundle):
    executable = bundle / MAC_HELPER_EXECUTABLE
    if bundle.is_symlink() or not executable.is_file() or executable.resolve() != bundle.resolve() / MAC_HELPER_EXECUTABLE:
        raise RuntimeError(f"Expected a MacHelper application at {bundle}")
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != MAC_HELPER_ID or \
            info.get("CFBundleExecutable") != executable.name:
        raise RuntimeError(f"The application at {bundle} is not the expected MacHelper.")


def quit_installed_mac_helper(bundle):
    executable = bundle / MAC_HELPER_EXECUTABLE
    pids = processes_at(executable)
    if not pids:
        return False
    for pid in pids:
        subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", QUIT_INSTALLED_APP,
                        str(pid), MAC_HELPER_ID, str(executable)], check=True, timeout=8)
    deadline = time.monotonic() + 8
    while processes_at(executable):
        if time.monotonic() >= deadline:
            raise RuntimeError("MacHelper is still running. Quit it and run the installer again.")
        time.sleep(0.05)
    return True


def reopen_mac_helper(bundle):
    # Opening the actual bundle through LaunchServices preserves its normal
    # login, UI and Accessibility identity. Keep the user's other app in front.
    subprocess.run(["/usr/bin/open", "-g", str(bundle)], check=True)
    deadline = time.monotonic() + 8
    while not processes_at(bundle / MAC_HELPER_EXECUTABLE):
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Installed MacHelper is at {bundle}, but its relaunch could not be confirmed.")
        time.sleep(0.05)


def install_app(source, destination):
    target = destination / source.name
    staging = Path(tempfile.mkdtemp(prefix=".install-", dir=destination))
    staged = staging / source.name
    previous = staging / "previous.app"
    installed = False
    was_running = False
    try:
        shutil.copytree(source, staged, symlinks=True)
        check_mac_helper(staged)
        if target.exists() or target.is_symlink():
            check_mac_helper(target)
            was_running = quit_installed_mac_helper(target)
        try:
            if target.exists():
                target.rename(previous)
            staged.rename(target)
            installed = True
        except BaseException:
            if previous.exists():
                try:
                    previous.rename(target)
                except OSError as restore_error:
                    raise RuntimeError(f"The prior MacHelper is preserved at {previous}; restoration failed.") from restore_error
            if was_running and target.exists():
                reopen_mac_helper(target)
            raise
        if was_running:
            reopen_mac_helper(target)
    finally:
        # Keep the only copy of the old app if restoring it failed.
        if installed or not previous.exists():
            shutil.rmtree(staging)
    return target


def main():
    source = ROOT / "dist/MacHelper.app"
    if not source.is_dir():
        raise SystemExit("Build MacHelper first with: python3 scripts/build-apps.py")
    destination = Path.home() / "Applications/LocalAIBaseTools"
    destination.mkdir(parents=True, exist_ok=True)
    # Serialize complete installs without leaving a lock file beside the app.
    lock = os.open(destination, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        subprocess.run([sys.executable, str(ROOT / "scripts/install-helper.py")], check=True)
        print(f"Installed {install_app(source, destination)}")
    finally:
        os.close(lock)
    retired = retire_legacy_translation(Path.home())
    if retired:
        print(f"Moved the old standalone Translation app to {retired}; its preferences were preserved.")
    print("Open MacHelper.app. Translation and Polish-input settings are under Extensions; launch at login is under General.")
    print("MacHelper requires Accessibility approval for selection; editing requires clicking Apply in a completed preview.")


if __name__ == "__main__":
    main()
