#!/usr/bin/env python3
"""Verify real Extensions list controls with isolated synthetic source tools.

The offscreen AppKit controller uses temporary sources/preferences, real worker
processes, and an injected source-folder opener. No AI, clipboard, user extension
folder, external editor, app permission, or Upwork interaction is used.
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
        subprocess.run(["swift", "build", "--package-path", str(ROOT / "MacHelper")],
                       check=True, capture_output=True, text=True, timeout=240)
        folder = Path(subprocess.run(
            ["swift", "build", "--package-path", str(ROOT / "MacHelper"), "--show-bin-path"],
            check=True, capture_output=True, text=True, timeout=30,
        ).stdout.strip())
    else:
        folder = Path()
    result = [args.host or folder / "MacHelperApp", args.worker or folder / "MacHelperScriptWorker",
              args.helper or folder / "mac-helper-host"]
    for path in result:
        if not path.is_file():
            raise RuntimeError("Missing executable: " + str(path))
    return [path.resolve() for path in result]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path)
    parser.add_argument("--worker", type=Path)
    parser.add_argument("--helper", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Extensions list checks require macOS and Swift command-line tools.")
    host, worker, helper = executables(args)
    with tempfile.TemporaryDirectory(prefix="mac-helper-extension-list-") as temporary:
        workspace = Path(temporary).resolve()
        if workspace.is_relative_to(ROOT.resolve()):
            raise RuntimeError("List verification must use an isolated temporary directory.")
        (workspace / ".mac-helper-list-verification").write_text("isolated-list-workspace\n")
        process = subprocess.Popen(
            [str(host), "--verify-extension-list", "--workspace-root", str(workspace),
             "--worker", str(worker), "--helper", str(helper)],
            cwd=workspace, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            stdout, stderr = process.communicate(timeout=150)
            lines = [line for line in stdout.splitlines() if line.strip()]
            if not lines:
                raise RuntimeError("List verification returned no report.\n" + stderr)
            report = json.loads(lines[-1])
            if process.returncode or not report.get("success"):
                raise RuntimeError("Extensions list verification failed:\n" + json.dumps(report, indent=2) + "\n" + stderr)
            assert report["hostPID"] == process.pid
            assert len(set(report["workerPIDs"])) >= 6
            for check in report["checks"]:
                print("PASS " + check)
            print(f"PASS one stable host and {len(set(report['workerPIDs']))} worker generations; all workers reaped")
            print("No real AI, source editor, user extension installation, app permission, clipboard, or Upwork interaction occurred.")
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
