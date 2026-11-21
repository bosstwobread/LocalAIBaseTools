"""Translate approved GitHub source into the marketplace's small public catalogs."""
import hashlib
import json
import re
from urllib.parse import quote

from discovery import LOCALE, MAX_DESCRIPTOR, discovery_entry, text, validate_descriptor

PREVIEW_LIMIT = 128 * 1024
PREVIEW_FIELDS = {
    "lookup": set(("description editorTitle documentHeading sentenceBefore word sentenceAfter meaningLabel "
                   "meaning sentenceLabel sentenceTranslation settings copy selectStep reviewStep resultStep").split()),
    "revision": set(("description editorTitle draft result resultLabel settings copy apply "
                     "selectStep reviewStep resultStep").split()),
    "image": {"description"},
}


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
    if set(value) - {"schemaVersion", "layout", "strings", "image", "fallbackImage", "icon", "category", "slug", "releaseZip"}:
        raise ValueError("Unknown marketplace preview fields.")
    layout, strings = value.get("layout"), value.get("strings")
    if not isinstance(layout, str) or layout not in PREVIEW_FIELDS:
        raise ValueError("Unknown marketplace preview layout.")
    if not isinstance(strings, dict) or "en" not in strings or len(strings) > 32:
        raise ValueError("Marketplace preview needs English and at most 32 locale tables.")
    required = PREVIEW_FIELDS[layout]
    allowed = required | ({"caption"} if layout == "image" else set())
    for locale, table in strings.items():
        if not LOCALE.fullmatch(locale) or not isinstance(table, dict) or not required <= table.keys() <= allowed:
            raise ValueError("Invalid marketplace preview locale or text fields.")
        for key, copy in table.items():
            if key in {"sentenceBefore", "sentenceAfter"} and isinstance(copy, str) and not copy.strip():
                if len(copy) > 80 or "\0" in copy:
                    raise ValueError("Invalid marketplace sentence fragment.")
            else:
                text(copy, "marketplace preview text", 1000 if key == "description" else 360, 4000)
    preview = {"schemaVersion": 1, "layout": layout, "strings": strings}
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
        if len(files["discovery.json"]) > MAX_DESCRIPTOR:
            raise ValueError("Published discovery descriptor exceeds 64 KiB.")
        descriptor = validate_descriptor(json.loads(files["discovery.json"]))
        identifier = manifest.get("identifier")
        if not isinstance(identifier, str) or descriptor.get("identifier", identifier) != identifier:
            raise ValueError("Conflicting registered extension identifiers.")
        validate_files(manifest, files)
        preview, listing = presentation(source, source.read("marketplace/preview.json", PREVIEW_LIMIT, optional=True))
        entry = discovery_entry(manifest, descriptor, listing.get("slug", identifier.replace(".", "-")))
        discovery.append(entry)

        inventory = [
            {"path": path, "url": source.raw_url(path), "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
            for path, raw in sorted(files.items())
        ]
        installer.append({
            "identifier": identifier, "displayName": entry["name"], "version": entry["version"],
            "summary": entry["summary"], "files": inventory,
        })
        tool = {key: value for key, value in entry.items() if key != "capabilities"}
        tool.update({
            "category": listing.get("category", "Productivity"), "icon": listing.get("icon", "assets/mac-helper.png"),
            "screenshots": [], "features": entry["capabilities"], "permissions": manifest["permissions"],
            "installSteps": descriptor.get("installSteps", []), "sourceUrl": source.url, "catalogUrl": "catalog.json",
        })
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
