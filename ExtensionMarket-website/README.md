# Extension Market website

Public marketplace: **https://local-ai-extension.nelson007.com/**

The website lists every current tool under `Extensions`, with search, category
and platform filters, interface previews, details, source links, and complete
source downloads. It is a static website served from its own Docker container.
It does not receive selected text, call an AI provider, or read visitor app state.

Translation's **Open MacHelper** link uses `machelper://install` to request a
native installation review. MacHelper checks the catalog and manifest before
showing permissions, then downloads the complete hash-verified source after
approval. Existing local edits, settings, and enabled/disabled choices survive
repeat install clicks. MessageHelper-Upwork is distributed as a complete ZIP
with Chrome/Edge Developer mode installation instructions.

## Files

- `index.html`, `styles.css`, `app.js`: buildless responsive interface.
- `assets/`: app/tool artwork and clearly labelled illustrative previews.
- `marketplace.config.json`: public URL, tool descriptions, and display metadata.
- `historical-packages/packages/`: immutable published source files and ZIPs.
  Builds retain these paths for older pinned catalogs and existing download links,
  while the current catalog lists only the latest versions. Translation 4.1.0's
  retained ZIP SHA-256 is `3f2f881578751ddcf445fc868212db96819c068369d786c29f72acd3c602be75`.
- `build.py`: discovers actual extension manifests, builds the source catalog,
  complete source ZIPs, and the prebuilt MacHelper app ZIP in `dist/`.
- `verify.py`: checks the built file inventories, package hashes, prefix-safe
  links, and the app archive's metadata and executable permissions.
- `test.cjs`: frontend behavior checks using the root project's jsdom dependency.
- `Dockerfile`, `nginx.conf`, `.dockerignore`: unprivileged static web container.
- `deploy.py`, `DEPLOYMENT.md`: the existing server's Docker/registry/Caddy
  deployment and rollback workflow. Private credentials stay outside this repo.

## Build and check

From the repository root:

```sh
python3 scripts/build-apps.py
python3 ExtensionMarket-website/build.py
python3 ExtensionMarket-website/verify.py
node --test ExtensionMarket-website/test.cjs
python3 -m unittest discover -s test -p marketplace_deploy_test.py -v
```

The published MacHelper ZIP is an Apple Silicon developer preview, signed with
the build machine's available Apple identity. It is not notarized. The site
labels the release and links the source; notarization is separate release work.
After moving the app to Applications and opening it, MacHelper sets up its
browser native host without requiring Python, Xcode, or administrator access.

For frontend-only development, `build.py --without-app` omits the app ZIP and
uses source links. Serve `dist/` locally; assets and links work at the production
domain root and also support a mounted path prefix.

## Deploy

```sh
python3 ExtensionMarket-website/deploy.py --dry-run
python3 ExtensionMarket-website/deploy.py --deploy
```

See [DEPLOYMENT.md](DEPLOYMENT.md) for the isolated container, baseline checks,
private configuration, and rollback. The live site uses its dedicated HTTPS
domain; the marketplace container stays separate from Serenity's database.

To add a tool, add its independent source folder under `Extensions`, optionally
add display metadata in `marketplace.config.json`, then rebuild and deploy.
Native catalog packages require a version-two JavaScript manifest. Browser
packages use their browser manifest and receive a download/install guide.
