"""Validate actual locale variants, escaping, bounds and complete image copy."""
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from preview_assets import LANGUAGES, PREVIEWS, SVG, build_previews, load_catalog, render_preview, text_width

HERE = Path(__file__).resolve().parent


class PreviewAssetTests(unittest.TestCase):
    def test_every_visible_text_field_and_accessible_description_has_a_catalog_key(self):
        catalog = load_catalog(HERE / 'preview-locales.json')
        for name in PREVIEWS:
            root = ET.parse(HERE / 'assets' / name).getroot()
            for node in root.iter():
                if node.tag not in {'{' + SVG + '}text', '{' + SVG + '}title', '{' + SVG + '}desc'}:
                    continue
                if not ''.join(node.itertext()).strip():
                    continue
                key = node.get('data-preview-key')
                if node.get('data-preview-preserve') in {'brand', 'symbol'}:
                    continue
                self.assertIn(key, catalog['en'], name + ': unlocalized visible or accessibility text')
                for locale in LANGUAGES:
                    self.assertIn(key, catalog[locale])

    def test_built_variants_use_localized_text_and_fit_their_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            catalog = build_previews(HERE, directory)
            self.assertIn('window.MARKET_PREVIEW_TRANSLATIONS', (directory / 'preview-locales.js').read_text())
            self.assertEqual(len(list((directory / 'assets/localized').rglob('*.svg'))), 26)
            for locale in LANGUAGES:
                for name in PREVIEWS:
                    root = ET.parse(directory / 'assets/localized' / locale / name).getroot()
                    self.assertEqual(root.get('lang'), locale)
                    for node in root.iter():
                        key = node.get('data-preview-key')
                        if key is None:
                            continue
                        actual = ' '.join(''.join(node.itertext()).split())
                        expected = ' '.join(catalog[locale][key].split())
                        # Tspan boundaries replace visual wrapping, not content.
                        self.assertEqual(actual.replace(' ', ''), expected.replace(' ', ''), locale + ': ' + key)
                        if node.tag == '{' + SVG + '}text':
                            self.assertEqual(node.get('direction'), 'rtl' if locale == 'ar' and node.get('data-preview-preserve') is None else 'ltr')
                            if not node.get('textLength'):
                                for span in node:
                                    self.assertLessEqual(text_width(span.text or '', float(node.get('font-size')), float(node.get('letter-spacing', 0))), float(node.get('data-preview-width')) + 0.01)

    def test_missing_locales_keys_invalid_text_and_unsafe_catalog_files_fail_build(self):
        original = json.loads((HERE / 'preview-locales.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'catalog.json'
            for change in ['locale', 'key', 'text']:
                value = json.loads(json.dumps(original))
                if change == 'locale':
                    value['locales'].pop('es')
                elif change == 'key':
                    value['locales']['es'].pop(next(iter(value['locales']['es'])))
                else:
                    value['locales']['es'][next(iter(value['locales']['es']))] = '<bad>\0'
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    load_catalog(path)
            path.unlink(); path.symlink_to(HERE / 'preview-locales.json')
            with self.assertRaises(ValueError):
                load_catalog(path)

    def test_catalog_text_is_escaped_as_data_in_svg(self):
        catalogs = load_catalog(HERE / 'preview-locales.json')
        catalogs['es']['translation.title'] = '<script>alert("test")</script> & synthetic'
        raw = render_preview(HERE / 'assets/translation-preview.svg', 'es', catalogs)
        parsed = ET.fromstring(raw)
        self.assertEqual(parsed.find('{' + SVG + '}title').text, catalogs['es']['translation.title'])
        self.assertNotIn(b'<script>', raw)
        self.assertNotIn('{' + SVG + '}script', [node.tag for node in parsed.iter()])

    def test_new_unmapped_image_text_fails_instead_of_silently_staying_english(self):
        catalogs = load_catalog(HERE / 'preview-locales.json')
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'preview.svg'
            path.write_text('<svg xmlns="http://www.w3.org/2000/svg"><text x="0" y="20">New unlocalized button</text></svg>')
            with self.assertRaisesRegex(ValueError, 'Unlocalized text'):
                render_preview(path, 'es', catalogs)


if __name__ == '__main__':
    unittest.main()
