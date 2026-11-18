#!/usr/bin/env python3
"""Build the static marketplace and complete, hash-verified source downloads."""
import argparse
import hashlib
import html
import io
import json
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlsplit
from discovery import read_descriptor, write_discovery_index
from preview_assets import build_previews

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# Keep publication deliberate. Never copy the repository tree or local runbooks.
PUBLIC_DOCUMENTS = (
    "AI_EXTENSION_GUIDE.md",
    "docs/Source-Extensions.md",
    "docs/Extension-Development.md",
    "docs/MacHelper-Protocol.md",
    "docs/Native-Extensions.md",
)
PUBLIC_SDK_FILES = {
    "NativeExtensionSDK/MacHelperNativeSDK.swift": "MacHelper/NativeExtensionSDK/MacHelperNativeSDK.swift",
}


def copy_public_documents(stage):
    for relative, original in {**{path: path for path in PUBLIC_DOCUMENTS}, **PUBLIC_SDK_FILES}.items():
        source = ROOT / original
        if source.is_symlink() or not source.is_file():
            raise ValueError("A public authoring document must be an ordinary file: " + relative)
        destination = stage / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    guide = html.escape((ROOT / "AI_EXTENSION_GUIDE.md").read_text())
    # Escaped Markdown is readable without JS, preserves complete copyable code,
    # and cannot turn document content into executable HTML.
    (stage / "developer-guide.html").write_text("""<!doctype html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Create or customize a MacHelper source extension with your AI coding assistant.">
<title>AI Extension Guide — LocalAI BaseTools</title><link rel="icon" href="./assets/mac-helper.png" type="image/png"><link rel="stylesheet" href="./styles.css"></head>
<body><main class="shell guide-page"><a class="text-link" href="./#developers">← Back to the Extension Market</a>
<p class="eyebrow">CREATE &amp; CUSTOMIZE</p><h1>Build a tool with your AI.</h1>
<p class="guide-intro">Download this Markdown file and give it to your AI coding assistant. Ask it to create an independent MacHelper source extension, or open an installed tool with Edit Source and ask it to help change the behavior. The complete guide appears below in its original, copyable format.</p>
<div class="guide-actions"><a class="button button-dark" href="./AI_EXTENSION_GUIDE.md" download="AI_EXTENSION_GUIDE.md">Download AI_EXTENSION_GUIDE.md ↓</a><a class="text-link" href="./#browse">Explore source tools ↗</a></div>
<nav class="guide-references" aria-label="Extension reference documents"><a href="./docs/Source-Extensions.md" download>Source extension reference ↓</a><a href="./docs/Extension-Development.md" download>Development reference ↓</a><a href="./docs/MacHelper-Protocol.md" download>AI protocol reference ↓</a><a href="./docs/Native-Extensions.md" download>Native worker reference ↓</a><a href="./NativeExtensionSDK/MacHelperNativeSDK.swift" download>Swift worker SDK ↓</a></nav>
<article class="guide-document" aria-label="Complete AI extension guide"><pre>""" + guide + """</pre></article></main></body></html>\n""")


def source_runtime(manifest):
    runtime = manifest.get("runtime")
    if manifest.get("schemaVersion") != 2 or runtime not in {"javascript", "native"}:
        raise ValueError("Unsupported marketplace source runtime.")
    entry = manifest.get("entryPoint")
    if not isinstance(entry, str) or not entry.endswith(".swift" if runtime == "native" else ".js"):
        raise ValueError("The source entry point does not match its declared runtime.")
    permissions = manifest.get("permissions")
    if not isinstance(permissions, list) or ("native.execute" in permissions) != (runtime == "native"):
        raise ValueError("Native source requires native.execute; JavaScript cannot request it.")
    return runtime


def validate_source_files(manifest, files):
    entry = manifest["entryPoint"]
    if entry not in files:
        raise ValueError("The source package entry point is missing.")
    try:
        if not files[entry].decode("utf-8").strip():
            raise ValueError("The source entry point is empty.")
        if manifest["runtime"] == "native":
            swift_files = sorted(path for path in files if Path(path).suffix.lower() == ".swift")
            if swift_files != [entry]:
                raise ValueError("Native source packages require exactly one Swift entry; the SDK is supplied by MacHelper.")
            for data in files.values():
                data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("Native source packages and source entry points require UTF-8 text, not prebuilt binaries.") from error


    resource_suffixes = {".js", ".json", ".txt", ".md", ".prompt"}
    if manifest["runtime"] == "native":
        resource_suffixes.add(".swift")
    resources = {name: data for name, data in files.items()
                 if name != "discovery.json" and not name.lower().startswith("readme") and Path(name).suffix.lower() in resource_suffixes}
    if sum(map(len, resources.values())) > 96 * 1024:
        raise ValueError("The source runtime text resources exceed 96 KiB.")
    path = manifest.get("localizations")
    if path is not None:
        if not isinstance(path, str) or not path.endswith(".json") or len(path.encode("utf-8")) > 512 or \
                len(path.split("/")) > 12 or any(not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_. -]{0,119}", part) for part in path.split("/")):
            raise ValueError("The UI translation catalog must use a safe relative JSON resource path.")
        data = resources.get(path)
        if data is None or len(data) > 64 * 1024:
            raise ValueError("The UI translation catalog is missing or exceeds 64 KiB.")
        try:
            catalog = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            raise ValueError("The UI translation catalog must be UTF-8 JSON.") from error
        if not isinstance(catalog, dict) or type(catalog.get("schemaVersion")) is not int or catalog["schemaVersion"] != 1 or \
                not isinstance(catalog.get("translations"), dict) or len(catalog["translations"]) > 32:
            raise ValueError("The UI translation catalog is invalid.")
        for locale, table in catalog["translations"].items():
            if not re.fullmatch(r"[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}", locale) or not isinstance(table, dict) or len(table) > 256:
                raise ValueError("The UI translation catalog has invalid language tables.")
            for source, translation in table.items():
                if not isinstance(translation, str) or not source or not translation or \
                        len(source.encode("utf-8")) > 2000 or len(translation.encode("utf-8")) > 8000 or "\0" in source or "\0" in translation:
                    raise ValueError("The UI translation catalog has invalid labels.")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_file(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def historical_files(folder=None):
    """Retain bounded public package bytes; never import arbitrary release files."""
    folder = folder or HERE / "historical-packages"
    if folder.is_symlink():
        raise ValueError("Historical packages cannot be a symbolic link.")
    if not folder.exists():
        return {}
    if not folder.is_dir():
        raise ValueError("Historical packages must be an ordinary directory.")
    result = {}
    for path in sorted(folder.rglob("*")):
        relative = path.relative_to(folder)
        if relative.parts[0] != "packages" or any(part.startswith(".") for part in relative.parts):
            raise ValueError("Historical files must use non-hidden packages/ paths: " + str(relative))
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if len(relative.parts) < 2 or not stat.S_ISREG(mode):
            raise ValueError("Historical packages cannot contain links or special files: " + str(relative))
        limit = 4 * 1024 * 1024 if relative.suffix == ".zip" else 512 * 1024
        if path.stat().st_size > limit:
            raise ValueError("Historical package file exceeds its limit: " + str(relative))
        result[relative.as_posix()] = path.read_bytes()
        if len(result) > 256 or sum(map(len, result.values())) > 8 * 1024 * 1024:
            raise ValueError("Historical package inventory exceeds its limits.")
    return result


def write_package(path, data):
    """Published versioned paths are immutable, including retained releases."""
    if path.exists() and path.read_bytes() != data:
        raise ValueError("A build cannot replace published package bytes: " + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def source_files(folder):
    """Package every ordinary non-hidden source file, including docs/licenses."""
    result = {}
    for path in sorted(folder.rglob("*")):
        relative = path.relative_to(folder)
        if any(part.startswith(".") or part in {"node_modules", "__pycache__"} for part in relative.parts):
            continue
        if path.is_symlink():
            raise ValueError("Source downloads cannot contain symbolic links: " + str(relative))
        if path.is_file():
            data = path.read_bytes()
            if len(data) > 512 * 1024:
                raise ValueError("An extension source file exceeds the package limit: " + str(relative))
            result[relative.as_posix()] = data
    if not result or len(result) > 128 or sum(map(len, result.values())) > 4 * 1024 * 1024:
        raise ValueError("The source inventory is empty or exceeds its package limits: " + folder.name)
    return result


def write_source_zip(path, folder_name, files):
    """Stable archives make source checksums reproducible across deployments."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            item = zipfile.ZipInfo(folder_name + "/" + name, date_time=(2026, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, data)
    write_package(path, buffer.getvalue())


def updated_at(folder):
    result = subprocess.run(["git", "log", "-1", "--format=%cI", "--", str(folder.relative_to(ROOT))],
                            cwd=ROOT, text=True, capture_output=True)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip().split("T", 1)[0]
    return datetime.fromtimestamp(max(p.stat().st_mtime for p in folder.rglob("*") if p.is_file()), timezone.utc).date().isoformat()


def build(output, app, without_app=False, allow_legacy_discovery=False):
    config = json.loads((HERE / "marketplace.config.json").read_text())
    base = config["baseUrl"]
    parsed = urlsplit(base)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or not base.endswith("/"):
        raise ValueError("The published marketplace baseUrl must be an absolute HTTPS directory URL.")
    output = output.resolve()
    if output == HERE or HERE not in output.parents or output.name != "dist":
        raise ValueError("The build output must be a dist directory inside ExtensionMarket-website.")
    with tempfile.TemporaryDirectory(prefix=".market-build-", dir=HERE) as temporary:
        stage = Path(temporary) / "site"
        stage.mkdir()
        for relative, data in historical_files().items():
            write_package(stage / relative, data)
        for filename in ["index.html", "styles.css", "locales.js", "i18n.js", "app.js"]:
            shutil.copy2(HERE / filename, stage / filename)
        shutil.copytree(HERE / "assets", stage / "assets")
        build_previews(HERE, stage)
        shutil.copy2(ROOT / "MacHelper/Assets/AppIcon.png", stage / "assets/mac-helper.png")
        copy_public_documents(stage)
        discovery_index, _ = write_discovery_index(ROOT, stage, config, allow_legacy_discovery)
        discovery_by_id = {item["id"]: item for item in discovery_index["extensions"]}
        catalog = {"schemaVersion": 1, "extensions": []}
        tools = []
        known = config.get("tools", {})
        seen_ids = set()
        seen_slugs = set()
        for folder in sorted((ROOT / "Extensions").iterdir()):
            if not folder.is_dir() or folder.name.startswith(".") or folder.name in config.get("retiredTools", []):
                continue
            metadata = known.get(folder.name, {})
            native_manifest = folder / "extension.json"
            browser_manifest = folder / "manifest.json"
            if native_manifest.exists():
                manifest = json.loads(native_manifest.read_text())
                runtime = source_runtime(manifest)
                kind = "mac-source"
                identifier = manifest["identifier"]
                name = manifest["displayName"]
                summary = manifest["summary"]
                permissions = manifest["permissions"]
                platforms = ["macOS"]
            elif browser_manifest.exists():
                manifest = json.loads(browser_manifest.read_text())
                kind = "browser"
                runtime = "browser"
                identifier = metadata.get("id", "com.localaibasetools." + folder.name.lower())
                name = manifest["name"]
                summary = manifest["description"]
                permissions = manifest.get("permissions", [])
                platforms = ["macOS", "Chrome", "Edge"]
            else:
                raise ValueError("An extension directory has no supported manifest: " + folder.name)
            discovery = read_descriptor(folder, {"summary": summary}, allow_legacy_discovery)
            if kind == "browser":
                identifier = discovery.get("identifier", identifier)
            platforms = discovery["platforms"]
            version = manifest["version"]
            if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
                raise ValueError("The source version must be a safe semantic version: " + folder.name)
            if not isinstance(identifier, str) or not re.fullmatch(r"[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)+", identifier) or len(identifier) > 128:
                raise ValueError("The source identifier must use reverse-domain notation: " + folder.name)
            slug = metadata.get("slug", folder.name.lower())
            if not slug or any(char not in "abcdefghijklmnopqrstuvwxyz0123456789-" for char in slug):
                raise ValueError("The extension slug is not URL-safe: " + slug)
            if identifier in seen_ids or slug in seen_slugs:
                raise ValueError("Duplicate extension identifier or slug.")
            seen_ids.add(identifier); seen_slugs.add(slug)
            files = source_files(folder)
            if kind == "mac-source":
                validate_source_files(manifest, files)
                inventory = []
                for relative, data in files.items():
                    url = "packages/" + slug + "/" + quote(version, safe="") + "/" + quote(relative, safe="/")
                    destination = stage / "packages" / slug / version / relative
                    write_package(destination, data)
                    inventory.append({"path": relative, "url": url, "sha256": digest(data), "size": len(data)})
                catalog["extensions"].append({
                    "identifier": identifier, "displayName": name, "version": version,
                    "summary": summary, "files": inventory,
                })
                package_name = "packages/" + slug + "-" + version + ".macsource.zip"
                write_source_zip(stage / package_name, identifier + ".macsource", files)
            else:
                package_name = "packages/" + slug + "-" + version + ".zip"
                complete = dict(files)
                complete.setdefault("LICENSE", (ROOT / "LICENSE").read_bytes())
                complete.setdefault("README.md", ("# " + name + "\n\n" + summary + "\n\n" +
                    "\n".join(str(i + 1) + ". " + step for i, step in enumerate(discovery.get("installSteps", []))) +
                    "\n\nComplete source: " + config["sourceUrl"] + "/tree/main/Extensions/" + folder.name + "\n").encode())
                write_source_zip(stage / package_name, folder.name, complete)
            item = {
                "id": identifier, "slug": slug, "name": name, "version": version,
                "summary": summary, "description": discovery["description"],
                "category": metadata.get("category", "Productivity"), "platforms": platforms,
                "kind": kind, "runtime": runtime,
                "icon": metadata.get("icon", "assets/mac-helper.png"),
                "screenshots": metadata.get("screenshots", []), "features": discovery["capabilities"],
                "keywords": discovery["keywords"], "exampleQueries": discovery["exampleQueries"],
                "limitations": discovery["limitations"], "translations": discovery["translations"],
                "permissions": permissions, "installSteps": discovery.get("installSteps", []),
                "sourceUrl": config["sourceUrl"] + "/tree/main/Extensions/" + quote(folder.name),
                "packageUrl": package_name, "packageSha256": digest((stage / package_name).read_bytes()),
                "packageSize": (stage / package_name).stat().st_size,
                "catalogUrl": "catalog.json" if kind == "mac-source" else None,
                "license": "MIT", "author": "LocalAIBaseTools contributors", "updatedAt": updated_at(folder),
            }
            if item["id"] not in discovery_by_id:
                raise ValueError("Published tool is missing from discovery metadata.")
            tools.append(item)
        mac = dict(config["macHelper"])
        mac.update({"sourceUrl": config["sourceUrl"], "marketplaceUrl": base,
                    "downloadUrl": "downloads/MacHelper-macOS-arm64.zip", "available": not without_app})
        if not without_app:
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") != "com.localaibasetools.mac-helper" or info.get("CFBundleShortVersionString") != mac["version"]:
                raise ValueError("Build the matching MacHelper " + mac["version"] + " app before publishing its download.")
            destination = stage / mac["downloadUrl"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(destination)], check=True)
            mac["sha256"] = digest(destination.read_bytes())
            mac["size"] = destination.stat().st_size
        else:
            mac["downloadUrl"] = None
        json_file(stage / "catalog.json", catalog)
        json_file(stage / "data/extensions.json", {"schemaVersion": 1, "name": config["name"], "extensions": tools, "macHelper": mac})
        (stage / "robots.txt").write_text("User-agent: *\nAllow: /\n")
        # A failed build never replaces the last complete website.
        previous = output.with_name(".previous-market-build")
        if previous.exists(): shutil.rmtree(previous)
        if output.exists(): output.rename(previous)
        try: stage.rename(output)
        except BaseException:
            if previous.exists(): previous.rename(output)
            raise
        if previous.exists(): shutil.rmtree(previous)
    return tools, mac


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=HERE / "dist")
    parser.add_argument("--app", type=Path, default=ROOT / "dist/MacHelper.app")
    parser.add_argument("--without-app", action="store_true", help="Local website development only; omits the app download.")
    args = parser.parse_args()
    try: tools, mac = build(args.output, args.app, args.without_app)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, "Marketplace build failed: " + str(error) + "\n")
    print("Built", args.output, "with", len(tools), "extensions and", len([t for t in tools if t["kind"] == "mac-source"]), "complete MacHelper source packages.")
    print("MacHelper download:", "included" if mac["available"] else "omitted for local development")


if __name__ == "__main__":
    main()
