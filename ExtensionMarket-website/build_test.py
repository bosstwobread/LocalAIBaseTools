"""Exercise native source packaging without changing the real website output."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import github_publication
from github_publication import PREVIEW_FIELDS, presentation

SOURCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("market_build", SOURCE / "build.py")
market = importlib.util.module_from_spec(spec)
spec.loader.exec_module(market)


def required_browser_companions():
    identity = "abcdefghijklmnop" * 2
    commit = "a" * 40
    raw = f"https://raw.githubusercontent.com/example/source/{commit}/browser.json"
    guide = f"https://github.com/example/source/blob/{commit}/README.md"
    return [
        {"browser": "chrome", "identifier": identity,
         "storeURL": "https://chromewebstore.google.com/detail/example/" + identity,
         "packageURL": raw, "packageSHA256": "b" * 64, "sourceURL": guide},
        {"browser": "edge", "identifier": identity,
         "packageURL": raw, "packageSHA256": "b" * 64},
        {"browser": "safari", "identifier": "org.example.safari", "sourceURL": guide},
    ]


class NativeSourcePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="market-native-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.site = self.root / "ExtensionMarket-website"
        self.site.mkdir()
        for name in ["index.html", "styles.css", "locales.js", "i18n.js", "app.js"]:
            shutil.copy2(SOURCE / name, self.site / name)
        shutil.copytree(SOURCE / "assets", self.site / "assets")
        (self.root / "MacHelper/Assets").mkdir(parents=True)
        shutil.copy2(SOURCE / "assets/mac-helper.png", self.root / "MacHelper/Assets/AppIcon.png")
        for path in market.PUBLIC_DOCUMENTS:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("Public reference: " + path + "\n")
        for path in market.PUBLIC_SDK_FILES.values():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("// public synthetic SDK fixture\n")
        (self.root / "AI_DEPLOYMENT.md").write_text("PRIVATE TEST SENTINEL\n")
        self.package = self.root / "Extensions/NativeExample"
        self.package.mkdir(parents=True)
        self.manifest = {
            "schemaVersion": 2, "runtime": "native", "identifier": "com.example.native-tool",
            "displayName": "Native Tool", "version": "1.0.0", "summary": "Synthetic native source.",
            "entryPoint": "Main.swift", "permissions": ["native.execute", "ui.panel"],
            "commands": [{"identifier": "run", "title": "Run", "trigger": "manual"}],
        }
        self.write_manifest()
        (self.package / "discovery.json").write_text(json.dumps({"schemaVersion":1,"description":"A synthetic native tool.","capabilities":["Show a native panel"],"exampleQueries":["Show a panel"],"keywords":["native"],"limitations":["Test only"],"platforms":["macOS"]}))
        (self.package / "Main.swift").write_text("// Synthetic source: packaging test does not execute it.\n")
        (self.package / "README.md").write_text("# Native Tool\n")
        (self.package / "LICENSE").write_text("MIT\n")
        config = {"name": "Fixture", "baseUrl": "https://market.example/", "sourceUrl": "https://source.example/repo", "macHelper": {"version": "6.0.0"}, "tools": {"NativeExample": {"slug": "native-example"}}}
        (self.site / "marketplace.config.json").write_text(json.dumps(config))

    def write_manifest(self):
        (self.package / "extension.json").write_text(json.dumps(self.manifest))

    def build(self):
        with patch.object(market, "ROOT", self.root), patch.object(market, "HERE", self.site):
            return market.build(self.site / "dist", self.root / "unused.app", without_app=True)

    def test_fallback_artwork_comes_from_approved_extension_files(self):
        activation = "https://raw.githubusercontent.com/independent/example/approved/"
        source = Mock()
        source.raw_url.side_effect = lambda path: activation + path
        preview = {
            "schemaVersion": 1,
            "layout": "revision",
            "strings": {locale: dict.fromkeys(PREVIEW_FIELDS["revision"], "Example") for locale in ("en", "es")},
            "fallbackImage": {"en": "preview.svg", "es": "localized/es/preview.svg"},
        }
        listing, _ = presentation(source, json.dumps(preview))
        self.assertEqual(listing["fallbackImage"], {
            "en": activation + "marketplace/preview.svg",
            "es": activation + "marketplace/localized/es/preview.svg",
        })
        self.assertEqual([call.args[0] for call in source.read.call_args_list],
                         ["marketplace/preview.svg", "marketplace/localized/es/preview.svg"])
        for invalid in ({}, {"es": "preview.svg"}, {"en": "../preview.svg"},
                        {"en": "https://other.example/preview.svg"}, {"en": "preview.svg", "ar": "preview.svg"}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                presentation(source, json.dumps({**preview, "fallbackImage": invalid}))

    def test_captions_preview_validates_static_original_and_translation_language(self):
        source = Mock()
        original = {"language": "es", "before": "Nos vemos en el ", "word": "banco", "after": " del parque."}
        preview = {"schemaVersion": 1, "layout": "captions", "sourceCaption": original,
                   "strings": {"en": dict.fromkeys(PREVIEW_FIELDS["captions"], "Example")}}
        preview["strings"]["en"]["translationLanguage"] = "de"
        result, _ = presentation(source, json.dumps(preview))
        self.assertEqual(result, preview)
        source.read.assert_not_called()
        for caption in ({}, {**original, "extra": "value"}, {**original, "language": "<img>"},
                        {**original, "before": None}, {**original, "after": "\0"}, {**original, "word": " "}):
            with self.subTest(caption=caption), self.assertRaises(ValueError):
                presentation(source, json.dumps({**preview, "sourceCaption": caption}))
        preview["strings"]["en"]["translationLanguage"] = "invalid_ locale"
        with self.assertRaises(ValueError):
            presentation(source, json.dumps(preview))

    def test_captions_preview_validates_fixed_target_without_localized_samples(self):
        source = Mock()
        target = {"language": "zh-Hans", "text": "把水烧开。", "meaning": "这里指加热到沸腾。"}
        preview = {
            "schemaVersion": 1, "layout": "captions",
            "sourceCaption": {"language": "en", "before": "", "word": "Boil", "after": " the water."},
            "targetCaption": target,
            "strings": {"en": {"description": "Try the sample", "close": "Close", "moveCaption": "Move captions"}},
        }
        result, _ = presentation(source, json.dumps(preview))
        self.assertEqual(result, preview)
        source.read.assert_not_called()
        for invalid in (None, {}, {**target, "language": "invalid_tag"}, {**target, "meaning": " "},
                        {**target, "text": "x" * 361}, {**target, "extra": "value"}):
            with self.subTest(target=invalid), self.assertRaises(ValueError):
                presentation(source, json.dumps({**preview, "targetCaption": invalid}))
        conflicting = {**preview["strings"]["en"], "translatedCaption": "Boil the water."}
        with self.assertRaises(ValueError):
            presentation(source, json.dumps({**preview, "strings": {"en": conflicting}}))
        with self.assertRaises(ValueError):
            presentation(source, json.dumps({"schemaVersion": 1, "layout": "image", "targetCaption": target,
                                             "strings": {"en": {"description": "Image"}}}))

    def test_standalone_github_extension_is_indexed_without_hosting_its_source(self):
        self.manifest["permissions"].append("companion.message")
        self.manifest["commands"].append({"identifier": "listen", "title": "Listen", "trigger": "companion"})
        self.manifest["companion"] = {"browsers": required_browser_companions()}
        self.write_manifest()
        commit = "1234567890abcdef1234567890abcdef12345678"
        source_url = f"https://github.com/independent/example/tree/{commit}"
        raw_prefix = f"https://raw.githubusercontent.com/independent/example/{commit}/"
        self.manifest["prebuiltWorker"] = self.prebuilt_worker()
        artifact = b"Publisher fixture for a separately hosted worker"
        self.manifest["prebuiltWorker"].update(size=len(artifact), sha256=hashlib.sha256(artifact).hexdigest())
        self.write_manifest()
        registry = self.site / "registry.json"
        registry.write_text(json.dumps({"schemaVersion": 1, "extensions": [source_url]}))
        files = {path.name: path.read_bytes() for path in self.package.iterdir()}
        files["marketplace/preview.json"] = json.dumps({
            "schemaVersion": 1, "layout": "image", "image": "preview.png",
            "strings": {"en": {"description": "An example preview."}},
            "releaseZip": "native-example.macsource.zip",
        }).encode()
        files["marketplace/preview.png"] = b"an illustrative fixture"
        self.package.rename(self.root / "standalone-checkout")

        def git_hash(data):
            return hashlib.sha1(f"blob {len(data)}\0".encode() + data, usedforsecurity=False).hexdigest()

        def pinned_tree(owner, repository, revision, folder):
            self.assertEqual((owner, repository, revision, folder), ("independent", "example", commit, ""))
            return b"".join(
                f"100644 blob {git_hash(raw)}\t{path}\0".encode()
                for path, raw in files.items()
            )

        def pinned_file(url, maximum):
            self.assertTrue(url.startswith(raw_prefix))
            raw = files[url.removeprefix(raw_prefix)]
            self.assertLessEqual(len(raw), maximum)
            return raw

        load_registry = market.read_registry
        with (patch.object(market, "read_registry", side_effect=lambda path, **kwargs:
                           load_registry(path, fetch=pinned_file, tree_reader=pinned_tree, **kwargs)),
              patch.object(github_publication, "fetch_raw", return_value=artifact) as fetch_worker):
            tools, _ = self.build()
            worker = self.manifest["prebuiltWorker"]
            fetch_worker.assert_called_once_with(worker["url"], len(artifact))
            output = self.site / "dist"
            catalog = json.loads((output / "catalog.json").read_text())
            discovery = json.loads((output / "discovery-index.json").read_text())
            tool, = tools
            entry, = catalog["extensions"]
            self.assertEqual(tool["sourceUrl"], source_url)
            self.assertEqual(tool["preview"]["image"], raw_prefix + "marketplace/preview.png")
            self.assertEqual(tool["packageUrl"], "https://github.com/independent/example/releases/download/v1.0.0/native-example.macsource.zip")
            self.assertIn("companion.message", tool["permissions"])
            self.assertIs(tool["hasPrebuiltWorker"], True)
            self.assertEqual(discovery["extensions"][0]["description"], "A synthetic native tool.")
            self.assertNotIn("hasPrebuiltWorker", discovery["extensions"][0])
            expected = {path: data for path, data in files.items() if not path.startswith("marketplace/")}
            self.assertEqual({record["path"] for record in entry["files"]}, set(expected))
            for record in entry["files"]:
                self.assertEqual(record["url"], raw_prefix + record["path"])
                self.assertEqual(record["sha256"], hashlib.sha256(expected[record["path"]]).hexdigest())
            self.assertFalse((output / "packages").exists())

            original = (output / "catalog.json").read_bytes()
            for invalid_artifact in (artifact[:-1], b"X" + artifact[1:]):
                with self.subTest(invalid_artifact=invalid_artifact):
                    fetch_worker.return_value = invalid_artifact
                    with self.assertRaisesRegex(ValueError, "does not match its declared byte size and SHA-256"):
                        self.build()
                    self.assertEqual((output / "catalog.json").read_bytes(), original)
            fetch_worker.return_value = artifact

            manifest_bytes = files["extension.json"]
            files["extension.json"] = json.dumps({**self.manifest, "prebuiltWorker": {
                **self.manifest["prebuiltWorker"], "url": raw_prefix + "Main.swift",
            }}).encode()
            with self.assertRaisesRegex(ValueError, "outside the editable source inventory"):
                self.build()
            self.assertEqual((output / "catalog.json").read_bytes(), original)

            legacy_companion = {"chromeExtensionID": self.manifest["companion"]["browsers"][0]["identifier"]}
            files["extension.json"] = json.dumps({**self.manifest, "companion": legacy_companion}).encode()
            with self.assertRaisesRegex(ValueError, r"Chrome, Edge, and Safari\."):
                self.build()
            self.assertEqual((output / "catalog.json").read_bytes(), original)
            files["extension.json"] = manifest_bytes

            files["marketplace/preview.json"] = b'{"schemaVersion":1,"layout":"html","html":"<script>invalid</script>"}'
            with self.assertRaises(ValueError):
                self.build()
            self.assertEqual((output / "catalog.json").read_bytes(), original)

    def prebuilt_worker(self):
        return {
            "url": "https://raw.githubusercontent.com/independent/native-workers/" + "a" * 40 + "/NativeTool-arm64",
            "sha256": "b" * 64,
            "size": 16384,
            "sourceSHA256": hashlib.sha256((self.package / "Main.swift").read_bytes()).hexdigest(),
            "teamIdentifier": "TEAM123456",
            "architecture": "arm64",
            "minimumOSVersion": "14.0",
            "protocolVersion": 1,
        }

    def test_registered_native_worker_pins_artifact_and_swift_entry(self):
        files = {"Main.swift": (self.package / "Main.swift").read_bytes()}
        with self.assertRaisesRegex(ValueError, "require a prebuiltWorker"):
            market.validate_registered_files(self.manifest, files)
        prebuilt = self.prebuilt_worker()
        manifest = {**self.manifest, "prebuiltWorker": prebuilt}
        market.validate_registered_files(manifest, files)
        market.validate_registered_files({**manifest, "prebuiltWorker": {
            **prebuilt, "architecture": "x86_64", "minimumOSVersion": "15.2.1", "size": 64 * 1024 * 1024,
        }}, files)
        with self.assertRaisesRegex(ValueError, "exact Swift entry file bytes"):
            market.validate_registered_files(manifest, {"Main.swift": files["Main.swift"] + b"\n"})
        cases = [
            ("url", prebuilt["url"].replace("a" * 40, "main")),
            ("url", prebuilt["url"].replace("/native-workers/", "/native-workers.git/")),
            ("url", prebuilt["url"].replace("/NativeTool", "/../NativeTool")),
            ("url", prebuilt["url"].replace("/NativeTool", "/%2e%2e/NativeTool")),
            ("url", prebuilt["url"].replace("https://", "https://user@")),
            ("url", prebuilt["url"].replace(".com/", ".com:443/")),
            ("url", prebuilt["url"] + "?download=1"),
            ("url", prebuilt["url"] + "#worker"),
            ("url", prebuilt["url"].replace("raw.githubusercontent.com", "github.com")),
            ("sha256", "B" * 64), ("size", 0), ("size", True), ("size", 64 * 1024 * 1024 + 1),
            ("sourceSHA256", "c" * 64), ("teamIdentifier", "team123456"), ("teamIdentifier", "TEAM12345"),
            ("architecture", "universal"), ("minimumOSVersion", "0.1"),
            ("minimumOSVersion", "14"), ("minimumOSVersion", "14.0.0.1"),
            ("protocolVersion", True), ("protocolVersion", 2),
        ]
        for field, invalid in cases:
            with self.subTest(field=field, invalid=invalid), self.assertRaisesRegex(ValueError, "prebuiltWorker"):
                market.validate_registered_files({**manifest, "prebuiltWorker": {**prebuilt, field: invalid}}, files)
        for invalid in (None, [], {}, {**prebuilt, "unknown": 1}):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "prebuiltWorker"):
                market.validate_registered_files({**manifest, "prebuiltWorker": invalid}, files)
        javascript = {**manifest, "runtime": "javascript", "entryPoint": "main.js", "permissions": []}
        with self.assertRaisesRegex(ValueError, "Only native source"):
            market.validate_registered_files(javascript, {"main.js": b"// Synthetic JavaScript source"})

    def test_registered_companion_manifest_requires_permission_exact_id_and_command(self):
        plain = {
            **self.manifest,
            "runtime": "javascript",
            "entryPoint": "main.js",
            "permissions": [],
        }
        files = {"main.js": b"// Synthetic JS source"}
        browsers = required_browser_companions()
        chrome_id = browsers[0]["identifier"]
        command = {"identifier": "listen", "title": "Listen", "trigger": "companion"}
        companion = {
            **plain,
            "permissions": ["companion.message"],
            "commands": plain["commands"] + [command],
            "companion": {"browsers": browsers},
        }
        market.validate_registered_files(plain, files)
        market.validate_registered_files(companion, files)
        cases = [
            {**plain, "companion": {"chromeExtensionID": chrome_id}},
            {**plain, "permissions": ["companion.message"]},
            {**plain, "commands": [command]},
            {**companion, "permissions": []},
            {**companion, "companion": None},
            {**companion, "commands": plain["commands"]},
        ]
        for malformed in ({}, [], {"chromeExtensionID": 4}, {"chromeExtensionID": chrome_id + "\n"},
                          {"chromeExtensionID": chrome_id.upper()}, {"chromeExtensionID": "q" * 32},
                          {"chromeExtensionID": chrome_id[:-1]}):
            cases.append({**companion, "companion": malformed})
        for manifest in cases:
            with self.subTest(manifest=manifest), self.assertRaisesRegex(ValueError, "[Cc]ompanion"):
                market.validate_registered_files(manifest, files)

    def test_marketplace_requires_chrome_edge_and_safari_for_browser_companions(self):
        browsers = required_browser_companions()
        firefox = {"browser": "firefox", "identifier": "@example",
                   "storeURL": "https://addons.mozilla.org/firefox/addon/example/"}
        market.validate_browser_companions({"browsers": browsers})
        market.validate_browser_companions({"browsers": [*browsers, firefox]})

        for missing in ("Chrome", "Edge", "Safari"):
            remaining = [item for item in browsers if item["browser"] != missing.lower()]
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, rf"Missing {missing}\."):
                market.validate_browser_companions({"browsers": [*remaining, firefox]})

    def test_browser_companion_declarations_pin_exact_install_and_development_sources(self):
        chrome, edge, safari = required_browser_companions()
        identity = chrome["identifier"]
        raw = chrome["packageURL"]
        guide = safari["sourceURL"]
        for items in (
            [chrome, chrome, edge, safari],
            [{**chrome, "storeURL": chrome["storeURL"].replace(identity, "a" * 32)}, edge, safari],
            [{**chrome, "packageURL": raw.replace("a" * 40, "main")}, edge, safari],
            [chrome, edge, {**safari, "sourceURL": guide.replace("/README.md", "/../README.md")}],
            [{**chrome, "packageSHA256": None}, edge, safari],
            [chrome, edge, {**safari, "packageURL": raw, "packageSHA256": "b" * 64}],
        ):
            with self.subTest(items=items), self.assertRaises(ValueError):
                market.validate_browser_companions({"browsers": items})

    def test_native_package_uses_unified_catalog_full_inventory_and_public_sdk(self):
        tools, _ = self.build()
        self.assertEqual(len(tools), 1)
        self.assertEqual(tools[0]["kind"], "mac-source")
        self.assertEqual(tools[0]["runtime"], "native")
        self.assertEqual(tools[0]["catalogUrl"], "catalog.json")
        output = self.site / "dist"
        catalog = json.loads((output / "catalog.json").read_text())
        expected = {"extension.json", "Main.swift", "README.md", "LICENSE", "discovery.json"}
        self.assertEqual({file["path"] for file in catalog["extensions"][0]["files"]}, expected)
        with zipfile.ZipFile(output / tools[0]["packageUrl"]) as archive:
            self.assertEqual(set(archive.namelist()), {"com.example.native-tool.macsource/" + path for path in expected})
        self.assertEqual((output / "NativeExtensionSDK/MacHelperNativeSDK.swift").read_text(), "// public synthetic SDK fixture\n")
        self.assertFalse(any(path.name == "AI_DEPLOYMENT.md" for path in output.rglob("*")))

    def test_native_package_can_include_a_declared_static_png_icon(self):
        self.manifest["icon"] = "assets/icon.png"
        self.write_manifest()
        resource = self.package / self.manifest["icon"]
        resource.parent.mkdir()
        pixel = base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF8sAAAAASUVORK5CYII="
        )
        resource.write_bytes(pixel)
        tools, _ = self.build()
        with zipfile.ZipFile(self.site / "dist" / tools[0]["packageUrl"]) as archive:
            self.assertEqual(archive.read("com.example.native-tool.macsource/assets/icon.png"), pixel)

        resource.write_bytes(b"Unrecognized binary")
        with self.assertRaisesRegex(ValueError, "icon must be a PNG"):
            self.build()

    def test_native_helper_sources_and_binary_resources_are_rejected(self):
        for relative, data in [("Extra.SWIFT", b"// unexpected helper"), ("worker", b"\xff\xfe\xfa\xce")]:
            with self.subTest(relative=relative):
                candidate = self.package / relative
                candidate.write_bytes(data)
                try:
                    with self.assertRaises(ValueError):
                        self.build()
                finally:
                    candidate.unlink()


    def test_declared_localizations_are_bounded_validated_and_packaged(self):
        self.manifest["localizations"] = "localizations.json"
        self.write_manifest()
        locale_file = self.package / "localizations.json"
        valid = {"schemaVersion": 1, "translations": {"ar": {"Run": "تشغيل"}, "zh-Hans": {"Run": "运行"}}}
        locale_file.write_text(json.dumps(valid, ensure_ascii=False))
        tools, _ = self.build()
        with zipfile.ZipFile(self.site / "dist" / tools[0]["packageUrl"]) as archive:
            self.assertEqual(json.loads(archive.read("com.example.native-tool.macsource/localizations.json")), valid)
        old = (self.site / "dist/catalog.json").read_bytes()
        cases = [
            b"not json", b"[]", json.dumps({"schemaVersion": True, "translations": {}}).encode(),
            json.dumps({"schemaVersion": 1, "translations": {"../ar": {}}}).encode(),
            json.dumps({"schemaVersion": 1, "translations": {"en": {"Run": 3}}}).encode(),
            json.dumps({"schemaVersion": 1, "translations": {"en": {"Run": "x" * 8001}}}).encode(),
            json.dumps({"schemaVersion": 1, "translations": {"en": {"Run": "a\0b"}}}).encode(),
            b" " * (64 * 1024 + 1),
        ]
        for data in cases:
            with self.subTest(data_size=len(data)):
                locale_file.write_bytes(data)
                with self.assertRaises(ValueError):
                    self.build()
                self.assertEqual((self.site / "dist/catalog.json").read_bytes(), old)
        locale_file.unlink()
        with self.assertRaises(ValueError):
            self.build()
        for path in ["../localizations.json", "localizations.txt", "README-localizations.json"]:
            with self.subTest(path=path):
                self.manifest["localizations"] = path
                self.write_manifest()
                with self.assertRaises(ValueError):
                    self.build()

    def test_localization_resources_count_toward_runtime_text_limit(self):
        self.manifest["localizations"] = "localizations.json"
        self.write_manifest()
        (self.package / "localizations.json").write_text(json.dumps({"schemaVersion": 1, "translations": {}}))
        (self.package / "large-prompt.txt").write_bytes(b"x" * (96 * 1024))
        with self.assertRaises(ValueError):
            self.build()

    def test_unapproved_native_or_mismatched_runtime_cannot_replace_public_output(self):
        self.build()
        old = (self.site / "dist/catalog.json").read_bytes()
        cases = [
            {"runtime": "native", "entryPoint": "Main.swift", "permissions": ["ui.panel"]},
            {"runtime": "javascript", "entryPoint": "main.js", "permissions": ["native.execute"]},
            {"runtime": "native", "entryPoint": "program", "permissions": ["native.execute"]},
            {"runtime": "shell", "entryPoint": "main.sh", "permissions": []},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                self.manifest.update(changes)
                self.write_manifest()
                with self.assertRaises(ValueError):
                    self.build()
                self.assertEqual((self.site / "dist/catalog.json").read_bytes(), old)


if __name__ == "__main__":
    unittest.main()
