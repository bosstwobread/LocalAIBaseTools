#!/usr/bin/env python3
"""Exercise native build/reload and runtime migration in an isolated MacHelper.

Uses real Swift compilation and independent workers with mocked AI. No user
extension folder, app permission, clipboard, selected text, or Upwork is touched.
"""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def executables(args):
    if not all((args.host, args.worker, args.helper)):
        subprocess.run(["swift", "build", "--package-path", str(ROOT / "MacHelper")], check=True, capture_output=True, text=True, timeout=240)
        folder = Path(subprocess.run(["swift", "build", "--package-path", str(ROOT / "MacHelper"), "--show-bin-path"], check=True, capture_output=True, text=True, timeout=30).stdout.strip())
    else:
        folder = Path()
    result = [args.host or folder / "MacHelperApp", args.worker or folder / "MacHelperScriptWorker", args.helper or folder / "mac-helper-host"]
    for executable in result:
        if not executable.is_file():
            raise RuntimeError("Missing executable: " + str(executable))
    return [path.resolve() for path in result]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path)
    parser.add_argument("--worker", type=Path)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--native-sdk", type=Path, default=ROOT / "MacHelper/NativeExtensionSDK/MacHelperNativeSDK.swift")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Native extension checks require macOS and Swift command-line tools.")
    host, worker, helper = executables(args)
    with tempfile.TemporaryDirectory(prefix="mac-helper-native-extensions-") as temporary:
        workspace = Path(temporary).resolve()
        if workspace.is_relative_to(ROOT.resolve()):
            raise RuntimeError("The native check must use an isolated temporary directory.")
        (workspace / ".mac-helper-native-verification").write_text("isolated-native-workspace\n")
        command = [str(host), "--verify-native-extensions", "--workspace-root", str(workspace),
                   "--worker", str(worker), "--helper", str(helper), "--native-sdk", str(args.native_sdk.resolve())]
        process = subprocess.Popen(command, cwd=workspace, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, stderr = process.communicate(timeout=300)
            lines = [line for line in stdout.splitlines() if line.strip()]
            if not lines:
                raise RuntimeError("The native verification harness returned no report.\n" + stderr)
            report = json.loads(lines[-1])
            if process.returncode or not report.get("success"):
                raise RuntimeError("Native extension verification failed:\n" + json.dumps(report, indent=2) + "\n" + stderr)
            assert report["hostPID"] == process.pid
            assert len(set(report["workerPIDs"])) >= 8
            for check in report["checks"]:
                print("PASS " + check)
            print(f"PASS stable host PID and {len(report['workerPIDs'])} independent worker generations; all workers reaped")
            print("No real AI request, Upwork action, clipboard mutation, user extension installation, or permission change occurred.")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=10)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
