#!/usr/bin/env python3
"""Create a complete source catalog; --ref pins downloads to a published Git commit."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', default='main')
    parser.add_argument('--base-url', help='Alternative source root, including trailing slash; useful for a marketplace/CDN.')
    args = parser.parse_args()
    package = ROOT / 'Extensions/Translation'
    manifest = json.loads((package / 'extension.json').read_text())
    base = args.base_url or f'https://raw.githubusercontent.com/bosstwobread/LocalAIBaseTools/{args.ref}/Extensions/Translation/'
    paths = sorted(path for path in package.rglob('*') if path.is_file() and not any(part.startswith('.') for part in path.relative_to(package).parts))
    files = []
    for path in paths:
        relative = path.relative_to(package).as_posix()
        data = path.read_bytes()
        files.append({'path': relative, 'url': base.rstrip('/') + '/' + relative,
                      'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)})
    entry = {key: manifest[key] for key in ['identifier', 'displayName', 'version', 'summary']}
    entry['files'] = files
    target = ROOT / 'catalog/extensions.json'
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps({'schemaVersion': 1, 'extensions': [entry]}, indent=2, ensure_ascii=False) + '\n')
    print(f'Built {target} ({len(files)} source files)')


if __name__ == '__main__':
    main()
