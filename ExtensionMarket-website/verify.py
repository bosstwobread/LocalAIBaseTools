#!/usr/bin/env python3
"""Check the actual public build, full source archives, and downloadable app."""
import hashlib
import html
import json
import plistlib
import sys
import zipfile
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from build import PUBLIC_DOCUMENTS, PUBLIC_SDK_FILES, historical_files, source_runtime

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

    for relative, original in {**{path: path for path in PUBLIC_DOCUMENTS}, **PUBLIC_SDK_FILES}.items():
        assert (site / relative).read_bytes() == (ROOT / original).read_bytes(), relative
    assert {path.relative_to(site / "docs").as_posix() for path in (site / "docs").rglob("*") if path.is_file()} == {
        relative.removeprefix("docs/") for relative in PUBLIC_DOCUMENTS if relative.startswith("docs/")
    }, "Only allowlisted extension references may be published in docs/."
    assert not any(path.name == "AI_DEPLOYMENT.md" for path in site.rglob("*")), "Private deployment runbook entered the public website."
    guide = (ROOT / "AI_EXTENSION_GUIDE.md").read_text()
    assert html.escape(guide) in (site / "developer-guide.html").read_text(), "The readable AI guide differs from the downloadable source."
    print("PASS the AI guide and allowlisted public references match source; the private runbook is excluded")

    def public_file(relative):
        assert isinstance(relative, str) and not urlsplit(relative).scheme and not relative.startswith("/")
        assert all(part not in {"", ".", ".."} for part in relative.split("/"))
        assert urljoin(config["baseUrl"], relative).startswith(config["baseUrl"])
        path = site / relative
        assert path.is_file() and path.stat().st_size > 0, relative
        return path

    history = historical_files()
    for relative, raw in history.items():
        assert public_file(relative).read_bytes() == raw, "Historical package changed: " + relative
    print("PASS", len(history), "historical package files remain byte-identical at their published paths")

    entries = {entry["identifier"]: entry for entry in catalog["extensions"]}
    for tool in data["extensions"]:
        public_file(tool["icon"])
        for screenshot in tool["screenshots"]: public_file(screenshot["src"])
        package = public_file(tool["packageUrl"])
        assert hashlib.sha256(package.read_bytes()).hexdigest() == tool["packageSha256"]
        assert package.stat().st_size == tool["packageSize"]
        with zipfile.ZipFile(package) as archive:
            assert all(not name.startswith("/") and ".." not in Path(name).parts for name in archive.namelist())
            assert all(Path(name).name != "AI_DEPLOYMENT.md" for name in archive.namelist()), "Private deployment runbook entered a source ZIP."
            if tool["kind"] == "mac-source":
                entry = entries[tool["id"]]
                prefix = tool["id"] + ".macsource/"
                assert set(archive.namelist()) == {prefix + item["path"] for item in entry["files"]}
                source = next(folder for folder in folders if (folder / "extension.json").exists() and json.loads((folder / "extension.json").read_text())["identifier"] == tool["id"])
                manifest = json.loads((source / "extension.json").read_text())
                assert source_runtime(manifest) == tool["runtime"]
                for item in entry["files"]:
                    raw = public_file(item["url"]).read_bytes()
                    assert hashlib.sha256(raw).hexdigest() == item["sha256"] and len(raw) == item["size"]
                    assert archive.read(prefix + item["path"]) == raw
                    assert (source / item["path"]).read_bytes() == raw
                assert {manifest["entryPoint"], "extension.json", "README.md", "LICENSE"}.issubset({item["path"] for item in entry["files"]})
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
            for relative, original in {**{path: path for path in PUBLIC_DOCUMENTS}, **PUBLIC_SDK_FILES}.items():
                assert archive.read("MacHelper.app/Contents/Resources/" + relative) == (ROOT / original).read_bytes(), "App guide/reference is stale: " + relative
            assert all(Path(name).name != "AI_DEPLOYMENT.md" for name in archive.namelist()), "Private deployment runbook entered the app download."
            assert not any(name.endswith("/settings.json") or "/.env" in name for name in archive.namelist())
        print("PASS MacHelper download has the correct version, marketplace URL, URL handler, icon, and executable permissions")
    else: print("SKIP developer-only build without the MacHelper download")


if __name__ == "__main__":
    try: main()
    except (AssertionError, KeyError, ValueError, OSError, zipfile.BadZipFile) as error:
        print("Marketplace verification failed: " + str(error), file=sys.stderr)
        sys.exit(1)
