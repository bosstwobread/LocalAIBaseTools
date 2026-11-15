#!/usr/bin/env python3
"""Check the actual public build, full source archives, and downloadable app."""
import hashlib
import json
import plistlib
import sys
import zipfile
from pathlib import Path
from urllib.parse import urljoin, urlsplit

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def main():
    site = HERE / "dist"
    data = json.loads((site / "data/extensions.json").read_text())
    catalog = json.loads((site / "catalog.json").read_text())
    config = json.loads((HERE / "marketplace.config.json").read_text())
    assert data["schemaVersion"] == catalog["schemaVersion"] == 1
    assert len({tool["id"] for tool in data["extensions"]}) == len(data["extensions"])
    assert len({tool["slug"] for tool in data["extensions"]}) == len(data["extensions"])
    folders = [p for p in (ROOT / "Extensions").iterdir() if p.is_dir() and not p.name.startswith(".")]
    assert len(folders) == len(data["extensions"]), "The website must list every extension directory."
    print("PASS every current extension is listed with a unique identity")

    def public_file(relative):
        assert isinstance(relative, str) and not urlsplit(relative).scheme and not relative.startswith("/")
        assert all(part not in {"", ".", ".."} for part in relative.split("/"))
        assert urljoin(config["baseUrl"], relative).startswith(config["baseUrl"])
        path = site / relative
        assert path.is_file() and path.stat().st_size > 0, relative
        return path

    entries = {entry["identifier"]: entry for entry in catalog["extensions"]}
    for tool in data["extensions"]:
        public_file(tool["icon"])
        for screenshot in tool["screenshots"]: public_file(screenshot["src"])
        package = public_file(tool["packageUrl"])
        assert hashlib.sha256(package.read_bytes()).hexdigest() == tool["packageSha256"]
        assert package.stat().st_size == tool["packageSize"]
        with zipfile.ZipFile(package) as archive:
            assert all(not name.startswith("/") and ".." not in Path(name).parts for name in archive.namelist())
            if tool["kind"] == "mac-source":
                entry = entries[tool["id"]]
                prefix = tool["id"] + ".macsource/"
                assert set(archive.namelist()) == {prefix + item["path"] for item in entry["files"]}
                source = ROOT / "Extensions/Translation"
                for item in entry["files"]:
                    raw = public_file(item["url"]).read_bytes()
                    assert hashlib.sha256(raw).hexdigest() == item["sha256"] and len(raw) == item["size"]
                    assert archive.read(prefix + item["path"]) == raw
                    if tool["id"] == "com.localaibasetools.translation": assert (source / item["path"]).read_bytes() == raw
                assert {"main.js", "extension.json", "prompts/translate.txt", "settings.schema.json", "README.md", "LICENSE"}.issubset({item["path"] for item in entry["files"]})
            else:
                prefix = "MessageHelper-Upwork/"
                for original in (ROOT / "Extensions/MessageHelper-Upwork").iterdir():
                    if original.is_file() and not original.name.startswith("."):
                        assert archive.read(prefix + original.name) == original.read_bytes()
                manifest = json.loads(archive.read(prefix + "manifest.json"))
                paths = {manifest["background"]["service_worker"], manifest["action"]["default_popup"]}
                for content in manifest["content_scripts"]: paths.update(content.get("js", []) + content.get("css", []))
                assert all(prefix + path in archive.namelist() for path in paths)
                assert prefix + "LICENSE" in archive.namelist() and prefix + "README.md" in archive.namelist()
    print("PASS source inventories, ZIP contents, hashes, icons, and previews match the actual projects")
    print("PASS all download and asset URLs remain within the mounted marketplace prefix")

    helper = data["macHelper"]
    if helper["available"]:
        package = public_file(helper["downloadUrl"])
        assert hashlib.sha256(package.read_bytes()).hexdigest() == helper["sha256"]
        with zipfile.ZipFile(package) as archive:
            app_info = plistlib.loads(archive.read("MacHelper.app/Contents/Info.plist"))
            assert app_info["CFBundleIdentifier"] == "com.localaibasetools.mac-helper"
            assert app_info["CFBundleShortVersionString"] == helper["version"]
            assert app_info["MacHelperMarketplaceURL"] == config["baseUrl"]
            assert any("machelper" in item["CFBundleURLSchemes"] for item in app_info["CFBundleURLTypes"])
            for binary in ["MacHelperApp", "mac-helper-host", "MacHelperScriptWorker"]:
                item = archive.getinfo("MacHelper.app/Contents/MacOS/" + binary)
                assert (item.external_attr >> 16) & 0o111, "Executable permissions were lost in the app archive."
            assert "MacHelper.app/Contents/Resources/AppIcon.icns" in archive.namelist()
            assert not any(name.endswith("/settings.json") or "/.env" in name for name in archive.namelist())
        print("PASS MacHelper download has the correct version, marketplace URL, URL handler, icon, and executable permissions")
    else: print("SKIP developer-only build without the MacHelper download")


if __name__ == "__main__":
    try: main()
    except (AssertionError, KeyError, ValueError, OSError, zipfile.BadZipFile) as error:
        print("Marketplace verification failed: " + str(error), file=sys.stderr)
        sys.exit(1)
