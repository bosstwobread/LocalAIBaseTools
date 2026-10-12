#!/usr/bin/env python3
"""Native messaging smoke tests. --live sends only synthetic text to GPT."""

import argparse
import json
import re
import select
import struct
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SAMPLE = (
    "Hi Morgan Test, I can delivers the demo by 2030-04-18 for $125.50. "
    "The preview URL is https://example.invalid/messagehelper-demo. "
    "Please confirms if that works."
)


class NativeClient:
    def __init__(self, executable):
        self.process = subprocess.Popen(
            [str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=0,
        )
        self.next_id = 0

    def read_exact(self, count, deadline):
        chunks = bytearray()
        while len(chunks) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("Native response timed out.")
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            if not ready:
                raise AssertionError("Native response timed out.")
            chunk = self.process.stdout.read(count - len(chunks))
            if not chunk:
                raise AssertionError("Native host ended before returning a complete frame.")
            chunks.extend(chunk)
        return bytes(chunks)

    def request(self, action, text="", timeout=15, **overrides):
        self.next_id += 1
        request = {
            "id": f"smoke-{self.next_id}", "action": action, "text": text,
            "targetLanguage": "zh-CN", "tone": "professional",
            **overrides,
        }
        payload = json.dumps(request, ensure_ascii=False).encode("utf-8")
        self.process.stdin.write(struct.pack("<I", len(payload)) + payload)
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        size = struct.unpack("<I", self.read_exact(4, deadline))[0]
        assert 0 < size <= 1024 * 1024, "Invalid native response frame size."
        response = json.loads(self.read_exact(size, deadline))
        assert response.get("id") == request["id"], "Native response ID mismatch."
        assert type(response.get("ok")) is bool, "Native response lacks a success flag."
        return response

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()
        self.process.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, default=ROOT / ".build/release/message-helper-host")
    parser.add_argument("--live", action="store_true", help="Translate/polish synthetic fixtures using existing ChatGPT login.")
    args = parser.parse_args()
    if not args.host.is_file():
        parser.error("Build the release host first with: swift build -c release")

    client = NativeClient(args.host)
    try:
        response = client.request("ping")
        assert response["ok"], "Native host ping failed."
        print("PASS native framing and ping")
        for action, text, overrides in [
            ("send", SAMPLE, {}),
            ("translate", "", {}),
            ("translate", "a" * 24001, {}),
            ("polish", SAMPLE, {"tone": "unsupported"}),
            ("translate", SAMPLE, {"targetLanguage": "unsupported"}),
        ]:
            rejected = client.request(action, text, **overrides)
            assert not rejected["ok"] and rejected.get("error"), "Invalid request was accepted."
        print("PASS invalid action, empty/oversized text, language and tone rejected")

        if args.live:
            translated = client.request("translate", SAMPLE, timeout=190)
            assert translated["ok"], "Live translation failed: " + translated.get("error", "unknown error")
            assert re.search(r"[\u4e00-\u9fff]", translated.get("text", "")), "Translation contains no Chinese text."
            print("PASS live Chinese translation of synthetic fixture")
            polished = client.request("polish", SAMPLE, timeout=190)
            assert polished["ok"], "Live polishing failed: " + polished.get("error", "unknown error")
            result = polished.get("text", "")
            assert result.strip(), "Polished result is empty."
            assert result.strip() != SAMPLE, "Polishing did not correct the fixture's grammar."
            for literal in ["Morgan Test", "2030-04-18", "$125.50", "https://example.invalid/messagehelper-demo"]:
                assert literal in result, "Polishing changed a protected name/date/amount/URL."
            print("PASS live polishing preserves name, date, amount and URL")
        else:
            print("Live GPT calls skipped; use --live to test synthetic fixtures.")
    finally:
        client.close()


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        sys.exit(1)
