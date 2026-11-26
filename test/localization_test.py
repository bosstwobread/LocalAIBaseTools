"""Keep native interface catalogs complete when a new UI string is introduced."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {"en", "zh-Hans", "zh-Hant", "es", "fr", "de", "ja", "ko", "pt", "ar", "hi", "ru", "it"}


class InterfaceCatalogTests(unittest.TestCase):
    def test_native_ui_source_keys_exist_in_every_catalog(self):
        folder = ROOT / "MacHelper/Runtime/Localization"
        files = {path.stem: path for path in folder.glob("*.json")}
        self.assertEqual(set(files), LANGUAGES)
        keys = set()
        for area in ["App", "Capabilities"]:
            for source in (ROOT / "MacHelper" / area).glob("*.swift"):
                for match in re.finditer(r'\bL\(("(?:[^"\\]|\\.)*")', source.read_text()):
                    keys.add(json.loads(match.group(1)))
        self.assertGreater(len(keys), 100)
        for code, path in files.items():
            with self.subTest(language=code):
                catalog = json.loads(path.read_text())
                self.assertFalse(keys - set(catalog), f"Missing UI keys: {sorted(keys - set(catalog))}")

if __name__ == "__main__":
    unittest.main()
