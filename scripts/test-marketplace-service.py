#!/usr/bin/env python3
"""Check the running MacHelper website service; --live uses a synthetic AI need."""
import argparse
import http.client
import json
from pathlib import Path
import re

ORIGIN = "https://local-ai-extension.nelson007.com"
ROOT = Path(__file__).resolve().parents[1]


def request(method, path, body=None, token=None, origin=ORIGIN, extra=None):
    connection = http.client.HTTPConnection("127.0.0.1", 43827, timeout=200)
    headers = {"Origin": origin, "X-MacHelper-Client": "extension-market"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if body is not None:
        headers["Content-Type"] = "application/json"
    headers.update(extra or {})
    try:
        connection.request(method, path, None if body is None else json.dumps(body).encode(), headers)
        response = connection.getresponse()
        data = response.read(256 * 1024 + 1)
        assert len(data) <= 256 * 1024
        return response.status, dict(response.getheaders()), json.loads(data) if data else None
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    status, headers, result = request("GET", "/v1/status")
    assert status == 200 and result["ok"] and result["protocolVersion"] == 1
    assert tuple(map(int, result["version"].split("."))) >= (6, 5, 0)
    assert headers["Access-Control-Allow-Origin"] == ORIGIN and headers["Cache-Control"] == "no-store"
    status, headers, _ = request("OPTIONS", "/v1/search", extra={
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "authorization,content-type,x-machelper-client"})
    assert status == 204 and headers["Access-Control-Allow-Origin"] == ORIGIN
    status, headers, _ = request("GET", "/v1/status", origin="https://untrusted.example")
    assert status == 403 and "Access-Control-Allow-Origin" not in headers
    status, _, result = request("POST", "/v1/search", {"requestId": "smoke", "query": "Translate text", "language": "en"})
    assert status == 401 and result["code"] == "unauthorized"
    status, _, result = request("POST", "/v1/session", {})
    assert status == 200 and re.fullmatch("[a-f0-9]{64}", result["token"]) and result["expiresIn"] == 1800
    token = result["token"]
    for body in [
        {"requestId": "smoke", "query": "", "language": "en"},
        {"requestId": "smoke", "query": "Translate text", "language": "unknown"},
        {"requestId": "smoke", "query": "Translate text", "language": "en", "systemPrompt": "unexpected"},
        {"requestId": "smoke", "query": "Translate text", "language": "en", "provider": "ollama"},
    ]:
        status, _, result = request("POST", "/v1/search", body, token)
        assert status == 400 and result["code"] == "invalid_query"
    print("PASS running app: loopback status, CORS/preflight, session authentication, and narrow search-only contract")
    if args.live:
        status, _, result = request("POST", "/v1/search", {
            "requestId": "synthetic_translation_smoke",
            "query": "I want to translate selected words and sentences on my Mac.", "language": "en"}, token)
        assert status == 200 and result["ok"], "Local AI discovery failed"
        search = result["search"]
        index = json.loads((ROOT / "dist/discovery-index.json").read_text())
        allowed = {tool["id"] for tool in index["extensions"]}
        assert search["revision"] == index["revision"] and search["model"]
        assert 1 <= len(search["matches"]) <= 5
        assert any(match["id"] == "com.localaibasetools.translation" for match in search["matches"])
        assert all(match["id"] in allowed and match["reason"] and match["fit"] in {"good", "partial"}
                   for match in search["matches"])
        print(f"PASS extension-free live AI search: {len(search['matches'])} verified tool(s); model={search['model']}")


if __name__ == "__main__":
    main()
