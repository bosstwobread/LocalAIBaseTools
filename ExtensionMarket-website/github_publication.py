"""Translate approved GitHub source into the marketplace's small public catalogs."""
import hashlib
import json
import re
from urllib.parse import quote

from discovery import LOCALE, MAX_PREVIEW as PREVIEW_LIMIT, registered_discovery_entry, text
from github_registry import fetch_raw

PREVIEW_FIELDS = {
    "lookup": set(("description editorTitle documentHeading sentenceBefore word sentenceAfter meaningLabel "
                   "meaning sentenceLabel sentenceTranslation settings copy selectStep reviewStep resultStep").split()),
    "revision": set(("description editorTitle draft result resultLabel settings copy apply "
                     "selectStep reviewStep resultStep").split()),
    "captions": {"description", "translatedCaption", "meaning", "close", "moveCaption"},
    "image": {"description"},
}


def preview_language(value):
    if not isinstance(value, str) or not LOCALE.fullmatch(value):
        raise ValueError("Invalid marketplace preview language.")
    return value


def image_url(source, value):
    if not isinstance(value, str) or len(value) > 240 or not re.fullmatch(
            r"[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\.(?:png|jpe?g|webp|avif|gif|svg)", value):
        raise ValueError("Preview images and icons must name an image inside marketplace/.")
    path = "marketplace/" + value
    source.read(path, 4 * 1024 * 1024)
    return source.raw_url(path)


def presentation(source, raw):
    if raw is None:
        return {}, {}
    value = json.loads(raw)
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise ValueError("Unsupported marketplace preview schema.")
    if set(value) - {"schemaVersion", "layout", "strings", "image", "fallbackImage", "icon", "category", "slug", "releaseZip", "sourceCaption", "targetCaption"}:
        raise ValueError("Unknown marketplace preview fields.")
    layout, strings = value.get("layout"), value.get("strings")
    if not isinstance(layout, str) or layout not in PREVIEW_FIELDS:
        raise ValueError("Unknown marketplace preview layout.")
    if not isinstance(strings, dict) or "en" not in strings or len(strings) > 32:
        raise ValueError("Marketplace preview needs English and at most 32 locale tables.")
    required = PREVIEW_FIELDS[layout]
    optional_fields = {"image": {"caption"}, "captions": {"translationLanguage"}}
    allowed = required | optional_fields.get(layout, set())
    if layout == "captions" and "targetCaption" in value:
        required = allowed = required - {"translatedCaption", "meaning"}
    for locale, table in strings.items():
        if not LOCALE.fullmatch(locale) or not isinstance(table, dict) or not required <= table.keys() <= allowed:
            raise ValueError("Invalid marketplace preview locale or text fields.")
        for key, copy in table.items():
            if key == "translationLanguage":
                preview_language(copy)
            elif key in {"sentenceBefore", "sentenceAfter"} and isinstance(copy, str) and not copy.strip():
                if len(copy) > 80 or "\0" in copy:
                    raise ValueError("Invalid marketplace sentence fragment.")
            else:
                text(copy, "marketplace preview text", 1000 if key == "description" else 360, 4000)
    preview = {"schemaVersion": 1, "layout": layout, "strings": strings}
    if layout == "captions":
        caption = value.get("sourceCaption")
        if not isinstance(caption, dict) or set(caption) != {"language", "before", "word", "after"}:
            raise ValueError("A captions preview requires one original caption and lookup word.")
        preview_language(caption["language"])
        for key in ("before", "after"):
            fragment = caption[key]
            if not isinstance(fragment, str) or "\0" in fragment or len(fragment.encode("utf-16-le")) > 480:
                raise ValueError("Invalid marketplace source caption fragment.")
        text(caption["word"], "marketplace lookup word", 80, 320)
        preview["sourceCaption"] = caption
        if "targetCaption" in value:
            target = value["targetCaption"]
            if not isinstance(target, dict) or set(target) != {"language", "text", "meaning"}:
                raise ValueError("A fixed target caption requires a language, translation, and word meaning.")
            preview_language(target["language"])
            text(target["text"], "marketplace target caption", 360, 4000)
            text(target["meaning"], "marketplace lookup meaning", 360, 4000)
            preview["targetCaption"] = target
    elif "sourceCaption" in value or "targetCaption" in value:
        raise ValueError("Only the captions preview layout accepts source and target captions.")
    if layout == "image":
        preview["image"] = image_url(source, value.get("image"))
    elif "image" in value:
        raise ValueError("Only the image preview layout accepts an image.")
    if "fallbackImage" in value:
        if layout == "image":
            raise ValueError("An image preview does not need an animation fallback.")
        fallback = value["fallbackImage"]
        if isinstance(fallback, dict):
            if "en" not in fallback or not fallback.keys() <= strings.keys():
                raise ValueError("Localized fallback images require English and matching preview locale tables.")
            preview["fallbackImage"] = {locale: image_url(source, filename) for locale, filename in fallback.items()}
        else:
            preview["fallbackImage"] = image_url(source, fallback)
    listing = {}
    if "category" in value:
        listing["category"] = text(value["category"], "marketplace category", 64, 256)
    if "icon" in value:
        listing["icon"] = image_url(source, value["icon"])
    if "slug" in value:
        listing["slug"] = value["slug"]
    if "releaseZip" in value:
        asset = value["releaseZip"]
        if not isinstance(asset, str) or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]{0,159}\.macsource\.zip", asset):
            raise ValueError("The release ZIP must be a .macsource.zip asset filename.")
        listing["releaseZip"] = asset
    return preview, listing


def verify_prebuilt_worker_artifact(worker, inventory):
    url, size = worker["url"], worker["size"]
    if any(item["url"] == url for item in inventory):
        raise ValueError("The prebuiltWorker artifact must stay outside the editable source inventory.")
    data = fetch_raw(url, size)
    if len(data) != size or hashlib.sha256(data).hexdigest() != worker["sha256"]:
        raise ValueError("The downloaded prebuiltWorker does not match its declared byte size and SHA-256.")


def collect_publications(sources, validate_files):
    """Return listings, installer inventories, and discovery entries from one revision per tool."""
    tools, installer, discovery = [], [], []
    for source in sources:
        files = source.files()
        if not {"extension.json", "discovery.json", "README.md", "LICENSE"} <= files.keys():
            raise ValueError("A registered source tool requires extension.json, discovery.json, README.md, and LICENSE.")
        manifest = json.loads(files["extension.json"])
        if not isinstance(manifest, dict):
            raise ValueError("Invalid registered extension manifest.")
        validate_files(manifest, files)
        preview, listing = presentation(source, source.read("marketplace/preview.json", PREVIEW_LIMIT, optional=True))
        entry, descriptor = registered_discovery_entry(manifest, files["discovery.json"], listing)
        identifier = entry["id"]
        discovery.append(entry)

        inventory = [
            {"path": path, "url": source.raw_url(path), "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
            for path, raw in sorted(files.items())
        ]
        worker = manifest.get("prebuiltWorker")
        if worker is not None:
            verify_prebuilt_worker_artifact(worker, inventory)
        installer.append({
            "identifier": identifier, "displayName": entry["name"], "version": entry["version"],
            "summary": entry["summary"], "files": inventory,
        })
        tool = {key: value for key, value in entry.items() if key != "capabilities"}
        app_icon = source.raw_url(manifest["icon"]) if manifest.get("icon") else "assets/mac-helper.png"
        tool.update({
            "category": listing.get("category", "Productivity"), "icon": listing.get("icon", app_icon),
            "screenshots": [], "features": entry["capabilities"], "permissions": manifest["permissions"],
            "installSteps": descriptor.get("installSteps", []), "sourceUrl": source.url, "catalogUrl": "catalog.json",
        })
        if worker is not None:
            tool["hasPrebuiltWorker"] = True
        if preview:
            tool["preview"] = preview
        if "releaseZip" in listing:
            repository = source.url.split("/tree/", 1)[0]
            tool["packageUrl"] = f"{repository}/releases/download/v{quote(entry['version'], safe='')}/{listing['releaseZip']}"
        tools.append(tool)
    catalog = {"schemaVersion": 1, "extensions": installer}
    if len(installer) > 256 or len(json.dumps(catalog, ensure_ascii=False, indent=2).encode("utf-8")) + 1 > 1024 * 1024:
        raise ValueError("The install catalog exceeds MacHelper's size limit.")
    return tools, catalog, discovery
