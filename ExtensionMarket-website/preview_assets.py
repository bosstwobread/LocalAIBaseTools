"""Build localized, code-native illustrations from one website-owned text catalog."""
import json
import math
import re
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path

LANGUAGES = ('en', 'zh-Hans', 'zh-Hant', 'es', 'fr', 'de', 'ja', 'ko', 'pt', 'ar', 'hi', 'ru', 'it')
PREVIEWS = ('translation-preview.svg', 'messagehelper-preview.svg')
SVG = 'http://www.w3.org/2000/svg'
ET.register_namespace('', SVG)


def load_catalog(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 512 * 1024:
        raise ValueError('Preview translations must be a bounded regular JSON file.')
    value = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(value, dict) or type(value.get('schemaVersion')) is not int or value['schemaVersion'] != 1:
        raise ValueError('Unsupported preview translation schema.')
    locales = value.get('locales')
    if not isinstance(locales, dict) or set(locales) != set(LANGUAGES):
        raise ValueError('Preview translations must cover all supported interface languages.')
    if not isinstance(locales['en'], dict):
        raise ValueError('Invalid English preview translation table.')
    keys = set(locales['en'])
    if not keys or len(keys) > 128 or not all(isinstance(key, str) and re.fullmatch(r'[a-z][A-Za-z0-9.]{0,99}', key) for key in keys):
        raise ValueError('Invalid preview translation keys.')
    for locale, table in locales.items():
        if not isinstance(table, dict) or set(table) != keys:
            raise ValueError('Incomplete preview translation catalog: ' + locale)
        for text in table.values():
            if not isinstance(text, str) or not text.strip() or len(text.encode('utf-8')) > 8000 or '\0' in text:
                raise ValueError('Invalid preview translation text: ' + locale)
    return locales


def text_width(text, size, spacing=0):
    # Conservative estimates keep language variants inside their illustration
    # fields. Actual browser font/layout checks complement these build bounds.
    units = 0
    for char in text:
        if unicodedata.category(char).startswith('M'):
            continue
        units += 1 if unicodedata.east_asian_width(char) in 'WF' else (0.32 if char.isspace() else 0.61)
    return units * size + max(0, len(text) - 1) * spacing


def wrap(text, width, size, spacing=0):
    lines = []
    for paragraph in text.split('\n'):
        # Split at spaces, with character-level fallback for unspaced scripts
        # and long tokens. Combining marks stay with their preceding character.
        tokens = re.findall(r'\S+\s*', paragraph) or ['']
        line = ''
        for token in tokens:
            if text_width(line + token.rstrip(), size, spacing) <= width:
                line += token
                continue
            if line.strip():
                lines.append(line.rstrip()); line = ''
            for char in token:
                if line and not unicodedata.category(char).startswith('M') and text_width(line + char, size, spacing) > width:
                    lines.append(line.rstrip()); line = ''
                line += char
        lines.append(line.rstrip())
    return lines


def render_preview(source, locale, catalogs):
    root = ET.fromstring(Path(source).read_bytes())
    root.set('lang', locale)
    root.set('{http://www.w3.org/XML/1998/namespace}lang', locale)
    for node in root.iter():
        key = node.get('data-preview-key')
        if node.tag in {'{' + SVG + '}text', '{' + SVG + '}title', '{' + SVG + '}desc'} and ''.join(node.itertext()).strip() and not key and node.get('data-preview-preserve') not in {'brand', 'symbol'}:
            raise ValueError('Unlocalized text in preview template: ' + ''.join(node.itertext()))
        if not key:
            continue
        if key not in catalogs[locale]:
            raise ValueError('Missing preview string: ' + key)
        text = catalogs[locale][key]
        for child in list(node):
            node.remove(child)
        node.text = text
        if node.tag != '{' + SVG + '}text':
            continue
        width = float(node.get('data-preview-width', '0'))
        if not math.isfinite(width) or width <= 0:
            raise ValueError('SVG text needs an explicit available width: ' + key)
        size = float(node.get('font-size', '16'))
        original_size = size
        spacing = float(node.get('letter-spacing', '0'))
        maximum_lines = int(node.get('data-preview-lines', '1'))
        if not 1 <= maximum_lines <= 5 or not 8 <= size <= 64:
            raise ValueError('Invalid preview text layout: ' + key)
        lines = wrap(text, width, size, spacing)
        while len(lines) > maximum_lines and size > 9:
            size = max(9, size - 0.5)
            lines = wrap(text, width, size, spacing)
        if len(lines) > maximum_lines:
            # Single-line labels can compress spacing instead of losing text.
            if maximum_lines != 1 or '\n' in text:
                raise ValueError('Preview translation does not fit its field: ' + key + ' / ' + locale)
            lines = [text]
            node.set('textLength', str(width)); node.set('lengthAdjust', 'spacingAndGlyphs')
        node.set('font-size', str(size).rstrip('0').rstrip('.') if '.' in str(size) else str(size))
        left = float(node.get('x', '0'))
        rtl = locale == 'ar' and node.get('data-preview-preserve') is None
        x = left + width if rtl else left
        node.set('x', str(x)); node.set('direction', 'rtl' if rtl else 'ltr')
        node.set('text-anchor', 'start'); node.set('unicode-bidi', 'plaintext')
        node.text = None
        line_height = float(node.get('data-preview-line-height', str(original_size * 1.4))) * size / original_size
        for index, line in enumerate(lines):
            span = ET.SubElement(node, '{' + SVG + '}tspan', {'x': str(x), 'dy': '0' if index == 0 else str(round(line_height, 2))})
            span.text = line
    return ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n'


def build_previews(site, output):
    site, output = Path(site), Path(output)
    catalogs = load_catalog(site / 'preview-locales.json')
    serialized = json.dumps(catalogs, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    (output / 'preview-locales.js').write_text('window.MARKET_PREVIEW_TRANSLATIONS = ' + serialized + ';\n', encoding='utf-8')
    for locale in LANGUAGES:
        directory = output / 'assets/localized' / locale
        directory.mkdir(parents=True, exist_ok=True)
        for name in PREVIEWS:
            (directory / name).write_bytes(render_preview(site / 'assets' / name, locale, catalogs))
    return catalogs
