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
    parser.add_argument('--output', type=Path, default=ROOT / 'catalog/extensions.json',
                        help='Write the generated inventory to this path.')
    parser.add_argument('--package', action='append', default=[], help='Source folder name under Extensions; repeat to select packages. Defaults to all source packages.')
    parser.add_argument('--base-url', help='Alternative URL root for one selected package; use with exactly one --package.')
    args = parser.parse_args()
    names = args.package or sorted(folder.name for folder in (ROOT / 'Extensions').iterdir()
                                   if folder.is_dir() and (folder / 'extension.json').is_file())
    if not names or len(set(names)) != len(names) or any(Path(name).name != name or name.startswith('.') for name in names):
        parser.error('Select distinct source folder names under Extensions.')
    if args.base_url and len(names) != 1:
        parser.error('--base-url requires exactly one selected --package.')
    entries = []
    identifiers = set()
    for name in names:
        package = ROOT / 'Extensions' / name
        if package.is_symlink() or not (package / 'extension.json').is_file():
            parser.error('Not an ordinary source package: ' + name)
        manifest = json.loads((package / 'extension.json').read_text())
        if manifest['identifier'] in identifiers:
            parser.error('Duplicate source package identifier.')
        identifiers.add(manifest['identifier'])
        base = args.base_url or f'https://raw.githubusercontent.com/bosstwobread/LocalAIBaseTools/{args.ref}/Extensions/{name}/'
        paths = sorted(path for path in package.rglob('*')
                       if path.is_file() and path.relative_to(package).parts[0] != 'marketplace'
                       and not any(part.startswith('.') for part in path.relative_to(package).parts))
        files = []
        for path in paths:
            if path.is_symlink():
                parser.error('Source package files cannot be symbolic links.')
            relative = path.relative_to(package).as_posix()
            data = path.read_bytes()
            files.append({'path': relative, 'url': base.rstrip('/') + '/' + relative,
                          'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)})
        entry = {key: manifest[key] for key in ['identifier', 'displayName', 'version', 'summary']}
        entry['files'] = files
        entries.append(entry)
    target = args.output
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({'schemaVersion': 1, 'extensions': entries}, indent=2, ensure_ascii=False) + '\n')
    print(f'Built {target} ({len(entries)} source packages)')


if __name__ == '__main__':
    main()
