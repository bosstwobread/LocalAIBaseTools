#!/usr/bin/env python3
"""Verify editable Translation downloads and hot reload with isolated real workers.

The default run uses a deterministic AI callback, temporary source/preferences,
and a loopback catalog. Add --live to send one public synthetic message through
the real local helper. No Upwork page, message, clipboard, permission, or user
extension installation is accessed.
"""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "com.localaibasetools.translation"


def build_executables(args):
    if not all((args.host, args.worker, args.helper)):
        completed = subprocess.run(
            ["swift", "build", "--package-path", str(ROOT / "MacHelper")],
            cwd=ROOT, text=True, capture_output=True, timeout=240,
        )
        if completed.returncode:
            raise RuntimeError("Swift build failed:\n" + completed.stdout + completed.stderr)
        binary_directory = Path(subprocess.run(
            ["swift", "build", "--package-path", str(ROOT / "MacHelper"), "--show-bin-path"],
            check=True, text=True, capture_output=True, timeout=30,
        ).stdout.strip())
    else:
        binary_directory = Path()
    result = [
        args.host or binary_directory / "MacHelperApp",
        args.worker or binary_directory / "MacHelperScriptWorker",
        args.helper or binary_directory / "mac-helper-host",
    ]
    for executable in result:
        if not executable.is_file():
            raise RuntimeError("Executable does not exist: " + str(executable))
    return [path.resolve() for path in result]


def fixture_files(directory):
    """Copy and serve every source file rather than a hand-picked runtime subset."""
    source = directory / "marketplace-author" / "Translation"
    shutil.copytree(
        ROOT / "Extensions" / "Translation", source,
        ignore=shutil.ignore_patterns(".DS_Store", "__pycache__", ".build", ".git"),
    )
    manifest = json.loads((source / "extension.json").read_text())
    if manifest["identifier"] != IDENTIFIER:
        raise RuntimeError("The Translation package has an unexpected identifier.")
    inventory = []
    served = {}
    for file in sorted(source.rglob("*")):
        if not file.is_file():
            continue
        if file.is_symlink():
            raise RuntimeError("The fixture must contain ordinary source files.")
        relative = file.relative_to(source).as_posix()
        data = file.read_bytes()
        served["/Translation/" + relative] = data
        inventory.append({
            "path": relative, "url": "Translation/" + quote(relative, safe="/"),
            "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
        })
    catalog = {"schemaVersion": 1, "extensions": [{
        "identifier": manifest["identifier"], "displayName": manifest["displayName"],
        "version": manifest["version"], "summary": manifest["summary"], "files": inventory,
    }]}
    served["/catalog.json"] = json.dumps(catalog).encode()
    broken = json.loads(json.dumps(catalog))
    for item in broken["extensions"][0]["files"]:
        item["url"] = "bad-Translation/" + quote(item["path"], safe="/")
        served["/bad-Translation/" + item["path"]] = (
            b"a deliberately corrupted marketplace download" if item["path"] == "main.js"
            else served["/Translation/" + item["path"]]
        )
    served["/broken-catalog.json"] = json.dumps(broken).encode()
    return served, inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, help="MacHelperApp executable; defaults to a local Swift build.")
    parser.add_argument("--worker", type=Path, help="MacHelperScriptWorker executable.")
    parser.add_argument("--helper", type=Path, help="mac-helper-host executable.")
    parser.add_argument("--live", action="store_true", help="Also translate one synthetic public sentence using the real AI service.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("MacHelper source-extension verification requires macOS and Xcode command-line tools.")
    host, worker, helper = build_executables(args)

    with tempfile.TemporaryDirectory(prefix="mac-helper-source-extensions-") as temporary:
        temporary = Path(temporary).resolve()
        if temporary.is_relative_to(ROOT.resolve()):
            raise RuntimeError("Verification must run outside the repository.")
        workspace = temporary / "isolated-user"
        workspace.mkdir(mode=0o700)
        (workspace / ".mac-helper-source-verification").write_text("isolated-test-workspace\n")
        served, inventory = fixture_files(temporary)
        requested = []
        lock = threading.Lock()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                path = unquote(urlsplit(self.path).path)
                if path == "/__requests":
                    with lock:
                        data = json.dumps({"paths": list(requested)}).encode()
                elif path in served:
                    with lock:
                        requested.append(path)
                    data = served[path]
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json" if path.endswith(".json") or path == "/__requests" else "text/plain")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, format, *values):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        command = [str(host), "--verify-source-extensions", "--catalog-url",
                   f"http://127.0.0.1:{server.server_port}/catalog.json", "--workspace-root", str(workspace),
                   "--worker", str(worker), "--helper", str(helper)]
        if args.live:
            command.append("--live")
        process = None
        try:
            process = subprocess.Popen(command, cwd=temporary, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            stdout, stderr = process.communicate(timeout=240 if args.live else 90)
            lines = [line for line in stdout.splitlines() if line.strip()]
            if not lines:
                raise RuntimeError("The headless harness returned no report.\n" + stderr)
            report = json.loads(lines[-1])
            if process.returncode or not report.get("success"):
                raise RuntimeError("Source extension verification failed:\n" + json.dumps(report, indent=2) + "\n" + stderr)
            assert report["hostPID"] == process.pid, report
            assert report["sourceFileCount"] == len(inventory), report
            assert len(set(report["workerPIDs"])) >= 6, report
            with lock:
                downloads = [path for path in requested if path.startswith("/Translation/")]
            expected = {"/Translation/" + item["path"] for item in inventory}
            assert set(downloads) == expected and len(downloads) == report.get("sourceDownloadCount", len(expected)), downloads
            for check in report["checks"]:
                print("PASS " + check)
            print(f"PASS one stable host and {len(report['workerPIDs'])} independent worker generations; all workers reaped")
            if args.live:
                print("Live local AI model: " + (report.get("liveModel") or "reported by local provider"))
                print(f"Live streaming: {report['liveProgressCount']} updates; first text {report['liveFirstPartialSeconds']:.2f}s; complete {report['liveCompletionSeconds']:.2f}s")
            print("No Upwork interaction, user extension directory, clipboard, or app permission was changed.")
        except subprocess.TimeoutExpired:
            if process is not None:
                process.kill()
                process.communicate(timeout=10)
            raise RuntimeError("The headless harness exceeded its bounded deadline; the host was stopped.")
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.communicate(timeout=10)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, subprocess.SubprocessError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
