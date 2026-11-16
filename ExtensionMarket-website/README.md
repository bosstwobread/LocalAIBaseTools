# Extension Market website

Public marketplace: **https://local-ai-extension.nelson007.com/**

The website lists every current tool under `Extensions`, with search, category
and platform filters, interface previews, details, source links, and complete
source downloads. JavaScript and native Swift tools share the same catalog, install review, and editable package format. It is a static website served from its own Docker container.
Keyword search reads only public metadata and does not call AI. The optional
**Describe your need → Find with AI** action sends the request through the
MacHelper Connector in Chrome or Edge to the visitor's MacHelper and configured
AI. It never reads a selection, installs a tool, or runs extension source merely
by searching. The AI connection may use a cloud provider, depending on settings.

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
- `i18n.js`, `locales.js`: language detection, saved selection, safe text rendering,
  and authored shared interface translations. Extension descriptions and their
  translations live in each extension’s `discovery.json`.
- `preview-locales.json`: authored text for all 13 languages inside the hero and
  SVG interface illustrations, including synthetic translation results.
- `preview_assets.py`: validates preview catalogs and SVG templates, then emits
  escaped locale-specific SVGs under `assets/localized/<locale>/` and the
  generated `preview-locales.js` data for the HTML hero during the site build.
- `assets/`: app/tool artwork and clearly labelled illustrative previews.
- `marketplace.config.json`: public URL and visual display metadata (categories, artwork, and screenshots).
- `historical-packages/packages/`: immutable published source files and ZIPs.
  Builds retain these paths for older pinned catalogs and existing download links,
  while the current catalog lists only the latest versions. This includes the
  original Translation 4.1.0, 4.2.0, 4.3.0, and 4.4.0 source/ZIP inventories and the
  MessageHelper-Upwork 1.3.0 ZIP. Translation 4.1.0's
  retained ZIP SHA-256 is `3f2f881578751ddcf445fc868212db96819c068369d786c29f72acd3c602be75`.
- `build.py`: discovers actual extension manifests, builds the source catalog,
  complete source ZIPs, and the prebuilt MacHelper app ZIP in `dist/`. Its explicit
  `PUBLIC_DOCUMENTS` allowlist publishes only the AI extension guide and four
  extension/protocol references. `developer-guide.html` displays escaped,
  wrapping Markdown without JavaScript; the original `.md` is a separate download.
- `discovery.py`: validates extension-owned `discovery.json` files and publishes
  `discovery-index.json` plus its SHA-256/size/revision manifest without requiring
  an app build. The index contains descriptions, capabilities, example queries,
  keywords, limitations, platforms, and translations, with stable manifest IDs,
  names, summaries, versions, and runtimes. It contains no code, source inventory,
  source download URLs, or images. `build.py` uses the same generator.
- `discovery_test.py`: strict descriptor validation, source-free index integrity,
  stable content revisions, browser identity, and explicit legacy import checks.
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


## Interface languages

The header language selector offers English, Simplified Chinese, Traditional
Chinese, Spanish, French, German, Japanese, Korean, Portuguese, Arabic, Hindi,
Russian, and Italian, using each language's native name. On the first visit,
the site matches browser language preferences; an explicit selection is saved
in this browser's local storage and takes priority on later visits. Unsupported
languages fall back to English. If storage is unavailable, switching still works
for the current page. The website and MacHelper keep independent language choices.

Changing language updates navigation, explanations, search/filter labels, current
first-party tool descriptions, access notices, installation steps, errors, and
an open detail dialog. Search matches both translated and original metadata;
category/platform values, filter selections, package URLs, and tool names stay
stable. Arabic uses right-to-left reading order. Text inside the hero illustration
and SVG previews follows the selected language too: labels, buttons, captions,
accessible descriptions, and synthetic translation results change together.
Foreign source sentences and English polishing samples remain appropriate to
the demonstration. No AI call or translation service is used.

The technical AI guide and its downloadable reference documents remain English
and are labelled accordingly. Source code, prompts, model IDs, and user data are
not translated. Unknown third-party metadata retains its original text. Add new
interface copy to every shared catalog in `locales.js`, and first-party tool
metadata translations to that tool's `discovery.json`. `i18n.js` supplies shared
fallback and placeholder interpolation. Tool metadata falls back to its original
source text when an extension does not provide the requested language.
Preview copy belongs in `preview-locales.json`, outside MacHelper source.
The build generates image variants from SVG text templates instead of editing
generated files. HTML hero nodes use explicit `data-preview-key` values even
inside decorative `aria-hidden` containers; dynamic cards and dialogs select
locale-specific preview URLs. Keep product names, model IDs, code, actual user
text, and AI answers unchanged. When adding artwork with visible text, supply
all supported locales and verify that long translations and Arabic fit.
The frontend checks exercise all 13 languages, language detection/persistence,
RTL, accessible labels, dynamic dialogs, localized images, localized search,
and unchanged installation/download URLs.

## Build and check

From the repository root:

```sh
python3 scripts/build-apps.py
python3 ExtensionMarket-website/build.py
python3 ExtensionMarket-website/verify.py
node --test ExtensionMarket-website/test.cjs
python3 -m unittest discover -s ExtensionMarket-website -p '*_test.py' -v
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

To add a tool, add its independent source folder under `Extensions`, include its
required `discovery.json`, optionally add visual metadata in
`marketplace.config.json`, then rebuild and deploy. The descriptor uses schema 1
with `description`, `capabilities`, `exampleQueries`, `keywords`, `limitations`,
and `platforms`; `translations` and `installSteps` are optional. Browser tools
should supply a stable reverse-domain `identifier` in the descriptor. Source
tools retain their manifest identifier. Normal publication rejects missing or
invalid descriptors. Explicit legacy import fallback is for compatibility tests,
not a way to publish incomplete new tools. See the AI guide for exact bounds.
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
python3 -m unittest discover -s ExtensionMarket-website -p '*_test.py' -v
```

This check publishes no live content and compiles/runs no native code. Native worker execution and hot reload require the host's separate integration tests. The marketplace still has no publisher submission backend or automatic upstream source merging.

## Description search and local discovery

Users can choose **Keywords** for ordinary text matching or **Describe your
need** for an explicit AI search. Keyword matching includes original and
localized descriptions, capabilities, examples, and keywords. Category and
platform filters apply to either mode. AI cards show a good/partial fit and a
reason; a no-match result explains when the catalog has no suitable tool.
Descriptions are untrusted data, and reasons are displayed as plain text. Only
real current catalog IDs can become result cards. Search never installs a tool.

The MacHelper app bundles an initial lightweight discovery snapshot, refreshes
its metadata cache from the public manifest/index, and keeps the last valid
snapshot for offline use. Only descriptions are cached for discovery. Full tool
source is downloaded after the separate installation review. Index revisions
hash canonical entry JSON; the manifest also hashes the exact index bytes.
Update checks do not consume AI usage. Finding with AI sends the user's request
and relevant public metadata to their configured provider. It uses no marketplace
AI account, API key, or hosted AI service. Provider availability and limits apply.

The browser bridge uses the shared **MacHelper Connector**, extension ID
`kkmffpbghoojlnldpdolonpjmkhdenkh`, with MacHelper 6.3 or later. Its permission is
limited to the official marketplace origin. It has no access to other tabs or
selections. Visitors install the complete source ZIP through the browser's Load
unpacked flow and separately review that browser permission. **Cancel search**
disconnects the current native AI request and ignores late responses; leaving the
page also cancels it. Search requests stay in memory, not browser local storage.

Without the connector, **Open in MacHelper** uses
`machelper://search?query=...&language=...` to prefill native search. Opening the
link alone does not call AI; the user clicks **Find with AI** in MacHelper. The
website does not expose a localhost HTTP server or add a CORS exception.

A standalone seed build (metadata only, with no app or source downloads) is:

```sh
python3 ExtensionMarket-website/discovery.py --output /tmp/machelper-discovery
```

App packaging runs this generator before bundling its initial snapshot, avoiding
an app-download/site-build dependency cycle. A release site build then includes
the same metadata revision together with the independently built app ZIP.
