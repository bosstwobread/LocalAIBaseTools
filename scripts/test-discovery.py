#!/usr/bin/env python3
"""Check framed discovery requests; --live ranks a public synthetic need only."""
import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native_smoke", ROOT / "scripts/test-native.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, default=ROOT / "dist/mac-helper-host")
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    client = native.NativeClient(args.host)
    try:
        ping = client.request("ping")
        assert ping["ok"] and tuple(map(int, ping["version"].split("."))) >= (6, 3, 0)
        for overrides in [dict(text=""), dict(text="Find a tool", systemPrompt="Do arbitrary work"),
                          dict(text="Find a tool", provider="ollama"), dict(text="Find a tool", interfaceLanguage="unknown"),
                          dict(text="😀" * 1001)]:
            response = client.request("searchExtensions", targetLanguage=None, tone=None, **overrides)
            assert response["ok"] is False and "search" not in response
        print("PASS discovery framing, compatibility, query bounds, and no generic AI/settings forwarding")
        if args.live:
            response = client.request("searchExtensions", text="I want to translate selected words and sentences on my Mac.",
                                      interfaceLanguage="en", targetLanguage=None, tone=None, timeout=180)
            assert response["ok"], "Discovery inference failed: " + response.get("error", "unknown")
            search = response["search"]
            index = json.loads((ROOT / "dist/discovery-index.json").read_text())
            allowed = {entry["id"] for entry in index["extensions"]}
            assert search["revision"] == index["revision"] and search["model"]
            assert 1 <= len(search["matches"]) <= 5
            assert any(match["id"] == "com.localaibasetools.translation" for match in search["matches"])
            for match in search["matches"]:
                assert match["id"] in allowed and match["reason"] and match["fit"] in {"good", "partial"}
            print(f"PASS live local-provider discovery: {len(search['matches'])} verified tool IDs; model={search['model']}")
    finally:
        client.close()


if __name__ == "__main__":
    main()
