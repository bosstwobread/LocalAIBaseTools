#!/usr/bin/env python3
"""Publish a bounded, source-free discovery index without requiring an app build."""
import argparse
import hashlib
import json
import re
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

MAX_DESCRIPTOR = 64 * 1024
MAX_INDEX = 16 * 1024 * 1024
LOCALE = re.compile(r'[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}')
IDENTIFIER = re.compile(r'[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*){1,7}')
VERSION = re.compile(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?')


def text(value, label, chars=1000, size=4000):
    if not isinstance(value, str) or not value.strip() or '\0' in value or len(value.encode('utf-16-le')) // 2 > chars or len(value.encode('utf-8')) > size:
        raise ValueError('Invalid discovery ' + label + '.')
    return value


def string_list(value, label, maximum, chars=1000, size=4000, minimum=1):
    if not isinstance(value, list) or not minimum <= len(value) <= maximum:
        raise ValueError('Invalid discovery ' + label + '.')
    return [text(item, label, chars, size) for item in value]


def validate_descriptor(value):
    if not isinstance(value, dict) or type(value.get('schemaVersion')) is not int or value['schemaVersion'] != 1:
        raise ValueError('Unsupported discovery descriptor schema.')
    allowed = {'schemaVersion', 'identifier', 'description', 'capabilities', 'exampleQueries', 'keywords', 'limitations', 'platforms', 'translations', 'installSteps'}
    if set(value) - allowed:
        raise ValueError('Unknown discovery descriptor fields.')
    result = {'description': text(value.get('description'), 'description', 4000, 16000)}
    for key, maximum, chars, size in [('capabilities',32,1000,4000),('exampleQueries',8,1000,4000),('keywords',32,128,512),('limitations',16,1000,4000),('platforms',8,128,512)]:
        result[key] = string_list(value.get(key), key, maximum, chars, size, minimum=0 if key in {'keywords','limitations'} else 1)
    if 'installSteps' in value:
        result['installSteps'] = string_list(value['installSteps'], 'installSteps', 16, 2000, 8000)
    if 'identifier' in value:
        if not isinstance(value['identifier'], str) or not IDENTIFIER.fullmatch(value['identifier']) or len(value['identifier'].encode('utf-8')) > 128:
            raise ValueError('Invalid discovery identifier.')
        result['identifier'] = value['identifier']
    translations = value.get('translations', {})
    if not isinstance(translations, dict) or len(translations) > 32:
        raise ValueError('Invalid discovery translations.')
    for locale, table in translations.items():
        if not LOCALE.fullmatch(locale) or not isinstance(table, dict) or len(table) > 256:
            raise ValueError('Invalid discovery language table.')
        for original, localized in table.items():
            text(original, 'translation key', 2000, 2000)
            text(localized, 'translation value', 8000, 8000)
    result['translations'] = translations
    return result


def read_descriptor(folder, legacy=None, allow_legacy=False):
    path = folder / 'discovery.json'
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError('Discovery metadata must be an ordinary file: ' + folder.name)
    if not path.exists():
        if not allow_legacy:
            raise ValueError('Publication requires discovery.json: ' + folder.name)
        # Explicit import/test compatibility only; never infer invented capabilities.
        summary = (legacy or {}).get('summary', 'Legacy extension metadata.')
        return validate_descriptor({'schemaVersion':1,'description':summary,'capabilities':[summary],'exampleQueries':[summary], 'keywords':['legacy'], 'limitations':['Legacy metadata: consult its source before installing.'], 'platforms':['macOS']})
    if path.stat().st_size > MAX_DESCRIPTOR:
        raise ValueError('Discovery descriptor exceeds 64 KiB: ' + folder.name)
    try:
        return validate_descriptor(json.loads(path.read_text(encoding='utf-8')))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError('Discovery metadata must be UTF-8 JSON: ' + folder.name) from error


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def build_discovery_index(root, config=None, allow_legacy=False):
    root = Path(root)
    config = config if config is not None else json.loads((root / 'ExtensionMarket-website/marketplace.config.json').read_text())
    entries = []
    for folder in sorted((root / 'Extensions').iterdir()):
        if folder.is_symlink():
            raise ValueError('Extensions cannot be symbolic links.')
        if not folder.is_dir() or folder.name.startswith('.') or folder.name in config.get('retiredTools', []):
            continue
        metadata = config.get('tools', {}).get(folder.name, {})
        source = folder / 'extension.json'
        browser = folder / 'manifest.json'
        if not source.exists() and not browser.exists():
            continue
        path = source if source.exists() else browser
        if path.is_symlink() or not path.is_file():
            raise ValueError('Extension manifest must be an ordinary file.')
        manifest = json.loads(path.read_text())
        summary = manifest.get('summary') if source.exists() else manifest.get('description')
        descriptor = read_descriptor(folder, {'summary':summary}, allow_legacy)
        identifier = manifest.get('identifier') if source.exists() else descriptor.get('identifier', metadata.get('id', 'com.localaibasetools.' + folder.name.lower()))
        slug = metadata.get('slug', folder.name.lower())
        entry = discovery_entry(manifest, descriptor, slug, source.exists(), identifier)
        if not source.exists() and metadata.get('id', identifier) != identifier:
            raise ValueError('Invalid or conflicting stable discovery identifier.')
        entries.append(entry)
    return discovery_documents(entries)


def discovery_entry(manifest, descriptor, slug, mac_source=True, identifier=None):
    identifier = identifier if identifier is not None else manifest.get('identifier')
    if not isinstance(identifier, str) or not IDENTIFIER.fullmatch(identifier) or len(identifier.encode('utf-8')) > 128:
        raise ValueError('Invalid stable discovery identifier.')
    if not isinstance(slug, str) or not re.fullmatch('[a-z0-9][a-z0-9-]{0,99}', slug):
        raise ValueError('Invalid discovery slug.')
    runtime = manifest.get('runtime') if mac_source else 'browser'
    if runtime not in {'javascript','native','browser'} or (mac_source and (manifest.get('schemaVersion') != 2 or runtime == 'browser')):
        raise ValueError('Unsupported discovery runtime.')
    name = text(manifest.get('displayName') if mac_source else manifest.get('name'), 'name', 256, 256)
    if any(unicodedata.category(char) in {'Cc','Cf'} for char in name):
        raise ValueError('Invalid discovery name control characters.')
    version = text(manifest.get('version'), 'version', 80, 80)
    if not VERSION.fullmatch(version):
        raise ValueError('Invalid discovery semantic version.')
    summary = manifest.get('summary' if mac_source else 'description')
    entry = {'id':identifier,'slug':slug,'name':name,'version':version,'summary':text(summary,'summary',2000,2000),
             'kind':'mac-source' if mac_source else 'browser','runtime':runtime}
    entry.update({key:descriptor[key] for key in ['description','capabilities','exampleQueries','keywords','limitations','platforms','translations']})
    return entry


def discovery_documents(entries):
    if len(entries) > 10000:
        raise ValueError('Discovery index exceeds 10,000 entries.')
    if any(len({entry[key] for entry in entries}) != len(entries) for key in ('id', 'slug')):
        raise ValueError('Duplicate discovery ID/slug.')
    revision = hashlib.sha256(json.dumps(entries,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')).hexdigest()
    updated = datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z')
    index = {'schemaVersion':1,'revision':revision,'updatedAt':updated,'extensions':entries}
    data = json_bytes(index)
    if len(data) > MAX_INDEX:
        raise ValueError('Discovery index exceeds 16 MiB.')
    manifest = {'schemaVersion':1,'revision':revision,'updatedAt':updated,'indexUrl':'discovery-index.json','sha256':hashlib.sha256(data).hexdigest(),'size':len(data)}
    return index, manifest


def write_discovery_index(root, output, config=None, allow_legacy=False):
    return write_discovery_documents(output, *build_discovery_index(root, config, allow_legacy))


def write_discovery_documents(output, index, manifest):
    output = Path(output); output.mkdir(parents=True,exist_ok=True)
    (output / 'discovery-index.json').write_bytes(json_bytes(index))
    (output / 'discovery-manifest.json').write_bytes(json_bytes(manifest))
    return index, manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    index, _ = write_discovery_index(args.root,args.output)
    print('Published discovery metadata for',len(index['extensions']),'extensions.')
