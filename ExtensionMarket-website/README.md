# Extension Market website

Public marketplace: **https://local-ai-extension.nelson007.com/**

The website lists every current tool under `Extensions`, with search, category
and platform filters, interface previews, details, source links, and complete
source downloads. JavaScript and native Swift tools share the same catalog, install review, and editable package format. It is a static website served from its own Docker container.
It does not receive selected text, call an AI provider, or read visitor app state.

**Create & customize** is available from the main navigation and every source
tool's details. Visitors can read the complete AI extension guide in the browser
or download [AI_EXTENSION_GUIDE.md](../AI_EXTENSION_GUIDE.md) for their coding
assistant. It explains both **Edit Source → save → hot reload** for an installed
enabled source tool and **Install Source… → enable** for a new independent tool.
JavaScript edits replace the script worker; native Swift edits build and replace
the native worker. Both keep MacHelper running. Chrome/Edge companions use the
browser's extension reload flow. Legacy compiled bundles require migration to
the current native source SDK.

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
  while the current catalog lists only the latest versions. This includes the
  original Translation 4.1.0 and 4.2.0 source/ZIP inventories. Translation 4.1.0's
  retained ZIP SHA-256 is `3f2f881578751ddcf445fc868212db96819c068369d786c29f72acd3c602be75`.
- `build.py`: discovers actual extension manifests, builds the source catalog,
  complete source ZIPs, and the prebuilt MacHelper app ZIP in `dist/`. Its explicit
  `PUBLIC_DOCUMENTS` allowlist publishes only the AI extension guide and four
  extension/protocol references. `developer-guide.html` displays escaped,
  wrapping Markdown without JavaScript; the original `.md` is a separate download.
- `verify.py`: checks the built file inventories, package hashes, prefix-safe
  links, and the app archive's metadata and executable permissions.
  It also checks public document bytes and rejects the private `AI_DEPLOYMENT.md`
  runbook anywhere in the published output. The repository tree is never copied
  wholesale into the site or its source packages.
- `test.cjs`: frontend behavior checks using the root project's jsdom dependency.
- `build_test.py`: isolated native-package/catalog and public SDK packaging checks.
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
python3 -m unittest discover -s ExtensionMarket-website -p build_test.py -v
python3 -m unittest discover -s test -p marketplace_deploy_test.py -v
```

The release configuration targets an Apple Silicon developer preview. The app
build prefers an available Apple signing identity and otherwise uses ad-hoc
signing; it does not perform notarization. The site
labels the release and links the source; notarization is separate release work.
After moving the app to Applications and opening it, MacHelper sets up its
browser native host without requiring Python, Xcode, or administrator access.
Enabling or editing a native Swift source tool separately requires Xcode
Command Line Tools. JavaScript source tools do not need that compiler.

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
Building the site, committing code, or pushing to GitHub does not deploy it.
`marketplace.config.json` describes the next build; the live release metadata is
served from `/data/extensions.json` and changes only after a successful rollout.

To add a tool, add its independent source folder under `Extensions`, optionally
add display metadata in `marketplace.config.json`, then rebuild and deploy.
MacHelper source packages require a schema-version-two manifest declaring
`runtime: "javascript"` or `"native"`. Browser packages use their browser manifest
and receive a download/install guide. If a browser source folder has no README
or license, the website ZIP includes a generated installation README and the
root project's license; source files already present in that folder are retained.

## Unified source runtimes

MacHelper 6 reads `runtime: "javascript"` or `"native"` from the schema-2 manifest. The website packages both as complete `.macsource.zip` inventories and uses the same Open MacHelper install link. Native source requires a `.swift` entry and `native.execute`; its detail/install page explains the compiler requirement and trusted native execution. No arbitrary native binary or manifest build hook is introduced by website packaging. The current Translation package remains JavaScript.

The authoring section and AI guide describe both adapters and migration with a stable identifier/settings. The public-document allowlist includes `docs/Native-Extensions.md`; a separate explicit mapping publishes `MacHelper/NativeExtensionSDK/MacHelperNativeSDK.swift` at `NativeExtensionSDK/MacHelperNativeSDK.swift`. The MacHelper download must bundle these exact public bytes. `AI_DEPLOYMENT.md` remains excluded from the website, source ZIPs, and app ZIP.

Check native catalog support using an isolated synthetic website/package fixture:

```sh
python3 -m unittest discover -s ExtensionMarket-website -p build_test.py -v
```

This check publishes no live content and compiles/runs no native code. Native worker execution and hot reload require the host's separate integration tests. The marketplace still has no publisher submission backend or automatic upstream source merging.
