#!/usr/bin/env python3
"""Native messaging smoke tests. --catalog discovers models; --live uses synthetic text only."""

import argparse
import json
import re
import select
import struct
import subprocess
import sys
import time
import unicodedata
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
    parser.add_argument("--host", type=Path, default=ROOT / "dist/mac-helper-host")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--live", action="store_true", help="Translate/polish synthetic fixtures using existing ChatGPT login.")
    mode.add_argument("--catalog", action="store_true", help="Discover the installed backend's current model catalog without inference.")
    parser.add_argument("--model", default="", help="Explicit model ID for --live; empty uses the desktop default.")
    args = parser.parse_args()
    if not args.host.is_file():
        parser.error("Build the release host first with: scripts/build-helper.sh")

    client = NativeClient(args.host)
    try:
        if args.catalog:
            catalog = client.request("listModels", timeout=60)
            assert catalog["ok"], "Model discovery failed: " + catalog.get("error", "unknown error")
            models = catalog.get("models")
            assert isinstance(models, list) and models, "Model catalog is empty or missing."
            identities = []
            for model in models:
                assert isinstance(model, dict), "Model entry is not an object."
                assert isinstance(model.get("model"), str) and model["model"].strip(), "Model entry has no ID."
                assert isinstance(model.get("displayName"), str) and model["displayName"].strip(), "Model entry has no label."
                assert type(model.get("isDefault")) is bool, "Model entry lacks a default flag."
                efforts = model.get("supportedReasoningEfforts", [])
                assert isinstance(efforts, list) and all(isinstance(effort, str) for effort in efforts), "Invalid reasoning effort list."
                if "defaultReasoningEffort" in model:
                    assert isinstance(model["defaultReasoningEffort"], str), "Invalid default reasoning effort."
                identities.append(model["model"])
            assert len(set(identities)) == len(identities), "Duplicate models in catalog."
            default_model = catalog.get("defaultModel", "")
            assert isinstance(default_model, str), "Invalid default model."
            assert len(default_model.encode("utf-8")) <= 200, "Default model ID is too long."
            assert not any(unicodedata.category(character) in {"Cc", "Cf"} for character in default_model), "Default model ID contains controls."
            assert not default_model or default_model.strip(), "Default model ID is whitespace-only."
            print(f"PASS dynamic catalog: {len(models)} models; default={default_model or 'desktop default'}")
            return

        response = client.request("ping")
        assert response["ok"], "Native host ping failed."
        print("PASS native framing and ping")
        for action, text, overrides in [
            ("send", SAMPLE, {}),
            ("translate", "", {}),
            ("translate", "a" * 24001, {}),
            ("polish", SAMPLE, {"tone": "unsupported"}),
            ("translate", SAMPLE, {"targetLanguage": "unsupported"}),
            ("polish", SAMPLE, {"model": ["invalid"]}),
            ("polish", SAMPLE, {"model": "invalid\nmodel"}),
            ("polish", SAMPLE, {"model": "m" * 201}),
        ]:
            rejected = client.request(action, text, **overrides)
            assert not rejected["ok"] and rejected.get("error"), f"Invalid request was accepted (action={action}, fields={','.join(overrides) or 'text'})."
        print("PASS invalid action, empty/oversized text, language, tone and model rejected")

        if args.live:
            translated = client.request("translate", SAMPLE, timeout=190, model=args.model)
            assert translated["ok"], "Live translation failed: " + translated.get("error", "unknown error")
            assert re.search(r"[\u4e00-\u9fff]", translated.get("text", "")), "Translation contains no Chinese text."
            if args.model:
                assert translated.get("model") == args.model, "Translation used a different model than selected."
            print("PASS live Chinese translation of synthetic fixture")
            polished = client.request("polish", SAMPLE, timeout=190, model=args.model)
            assert polished["ok"], "Live polishing failed: " + polished.get("error", "unknown error")
            result = polished.get("text", "")
            assert result.strip(), "Polished result is empty."
            assert result.strip() != SAMPLE, "Polishing did not correct the fixture's grammar."
            if args.model:
                assert polished.get("model") == args.model, "Polishing used a different model than selected."
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
