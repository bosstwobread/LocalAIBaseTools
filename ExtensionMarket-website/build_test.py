"""Exercise native source packaging without changing the real website output."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SOURCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("market_build", SOURCE / "build.py")
market = importlib.util.module_from_spec(spec)
spec.loader.exec_module(market)


class NativeSourcePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="market-native-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.site = self.root / "ExtensionMarket-website"
        self.site.mkdir()
        for name in ["index.html", "styles.css", "locales.js", "i18n.js", "app.js", "preview-locales.json"]:
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

    def test_standalone_github_extension_is_indexed_without_hosting_its_source(self):
        commit = "1234567890abcdef1234567890abcdef12345678"
        source_url = f"https://github.com/independent/example/tree/{commit}"
        raw_prefix = f"https://raw.githubusercontent.com/independent/example/{commit}/"
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
        with patch.object(market, "read_registry", side_effect=lambda path, **kwargs:
                          load_registry(path, fetch=pinned_file, tree_reader=pinned_tree, **kwargs)):
            tools, _ = self.build()
            output = self.site / "dist"
            catalog = json.loads((output / "catalog.json").read_text())
            discovery = json.loads((output / "discovery-index.json").read_text())
            tool, = tools
            entry, = catalog["extensions"]
            self.assertEqual(tool["sourceUrl"], source_url)
            self.assertEqual(tool["preview"]["image"], raw_prefix + "marketplace/preview.png")
            self.assertEqual(tool["packageUrl"], "https://github.com/independent/example/releases/download/v1.0.0/native-example.macsource.zip")
            self.assertEqual(discovery["extensions"][0]["description"], "A synthetic native tool.")
            expected = {path: data for path, data in files.items() if not path.startswith("marketplace/")}
            self.assertEqual({record["path"] for record in entry["files"]}, set(expected))
            for record in entry["files"]:
                self.assertEqual(record["url"], raw_prefix + record["path"])
                self.assertEqual(record["sha256"], hashlib.sha256(expected[record["path"]]).hexdigest())
            self.assertFalse((output / "packages").exists())

            original = (output / "catalog.json").read_bytes()
            files["marketplace/preview.json"] = b'{"schemaVersion":1,"layout":"html","html":"<script>invalid</script>"}'
            with self.assertRaises(ValueError):
                self.build()
            self.assertEqual((output / "catalog.json").read_bytes(), original)

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
