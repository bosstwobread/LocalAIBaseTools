"""Exercise native source packaging without changing the real website output."""
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

    def test_native_package_uses_unified_catalog_full_inventory_and_public_sdk(self):
        tools, _ = self.build()
        self.assertEqual(len(tools), 1)
        self.assertEqual(tools[0]["kind"], "mac-source")
        self.assertEqual(tools[0]["runtime"], "native")
        self.assertEqual(tools[0]["catalogUrl"], "catalog.json")
        output = self.site / "dist"
        catalog = json.loads((output / "catalog.json").read_text())
        expected = {"extension.json", "Main.swift", "README.md", "LICENSE"}
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
