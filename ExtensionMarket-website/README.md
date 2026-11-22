# Extension Market website

Public marketplace: **https://local-ai-extension.nelson007.com/**

The marketplace lists the extensions registered in `registry.json`, with
search, category and platform filters, interface previews, details, source
links, and complete source downloads. JavaScript and native Swift tools share
the same catalog, install review, and editable package format. The website is
static and served from its own Docker container.
Keyword search reads only public metadata and does not call AI. The optional
**Describe your need → Find with AI** flow connects
directly to the visitor’s running MacHelper 6.5 or later and configured AI. No
browser extension is needed for website search. It never reads a selection, installs a tool, or runs extension source merely
by searching. The AI connection may use a cloud provider, depending on settings.

**Create & customize** is available from the main navigation and every source
tool's details. Visitors can read the complete AI extension guide in the browser
or download [AI_EXTENSION_GUIDE.md](../AI_EXTENSION_GUIDE.md) for their coding
assistant. It explains both **Edit Source → save → hot reload** for an installed
enabled source tool and **Install Source… → enable** for a new independent tool.
JavaScript edits replace the script worker; native Swift edits build and replace
the native worker. Both keep MacHelper running. Legacy compiled bundles require migration to
the current native source SDK.

The **Open MacHelper** links for Translation and Polish-input use `machelper://install` to request a
native installation review. MacHelper checks the catalog and manifest before
showing permissions, then downloads the complete hash-verified source after
approval. Existing local edits, settings, and enabled/disabled choices survive
repeat install clicks. Users can install a newer catalog version through
**Update…** in MacHelper after reviewing the release. Both current tools run
through MacHelper without a browser extension. MacHelper 6.6 adds a shared
Translate/Polish selection toolbar;
6.6.1 presents separate icons with nonoverlapping click areas, localized tooltips,
and an ellipsis menu when more than five actions are enabled.
MacHelper also hides the waiting toolbar while Command is held; releasing
Command alone does not reopen it, while an existing result panel stays open.
Keyboard selections such as Command-A are latched at key-down and wait for both
keys to be released, in either order. MacHelper 6.7.2 reads the Command flag on
the next mouse gesture even if a prior key release was missed. A timed-out
Accessibility source check after Copy gets a bounded recheck of the same
selection context without another clipboard operation.
Its bounded Accessibility reader checks the selected mouse location, fixed
application/system-focus routes, and focused/main window or application selection
providers. It reads only verified selected numeric or marker spans, including
same-range attributed-text fallback; it never crawls arbitrary descendants or
reads an entire document to find a selection. MacHelper 6.7 adds an automatic
fixed Copy fallback after recognized selection gestures when Accessibility cannot
read the selection. It snapshots bounded, stable, fully readable clipboard data
in memory, reads only newly copied text, then restores only while that clipboard
state still belongs to the attempt. Before Copy, at most three bounded preparation
checks allow the same gesture’s menu/clipboard to settle, with 60 milliseconds
of clipboard quiet and a 0.5-second snapshot budget. Once Copy is attempted, it
is never retried. No manual switch is required; ordinary clicks,
activation, and polling never trigger Copy. Protected fields, explicit carets,
invalid/stale contexts, and unreadable or oversized clipboards skip the fallback.
Text obtained solely by Copy has no numeric editing proof or sentence context.
At tool click, a fresh matching Accessibility read can recover the original
control’s numeric range and origin only while the original context is unchanged;
all normal editing checks still apply. If MacHelper cannot verify either an exact edit target or an eligible Paste menu target, Apply stays disabled. The completed preview offers Copy and explains why.
Coverage and restoration are best effort, and clipboard-history tools may see the
temporary change. There is no macOS Services or OCR capture fallback and no
screen-reading permission request. These shared host changes need no extension
behavior change.
For a clipboard-captured selection, **Apply** can use the original editor’s standard Paste command when MacHelper can verify the window and its editing commands. Keep the text selected while reviewing the preview. This method leaves the result on the clipboard. **Copy** remains available.

Polish-input streams a preview. **Apply** updates a supported editable selection,
and **Copy** is available for manual use.
MacHelper identifies supported web editors through a bounded Accessibility
parent-chain check, including editors embedded in desktop apps. These select
approved paste before any write because an advertised selected-text setter may
ignore direct edits. Verified native controls prefer direct selected-text editing;
if the bounded check cannot determine the editor type, only approved paste is
eligible with the same strict editable-field and selection checks. That Apply route requires numeric selection evidence. A tool with separately approved
`selection.paste` access may use clipboard-assisted Apply in a supported editor:
only after you click **Apply**, MacHelper rechecks the original app, focused field,
selection range, and exact text, writes the completed result to the clipboard,
and sends the fixed Paste shortcut to that app. This replaces the clipboard and
leaves the result there; this Apply transaction never reads or restores previous
clipboard contents. Automatic selection capture is a separate guarded operation.
It does not retry a failed direct edit by pasting, or press Enter or Send. Changed, protected, read-only, or unsupported
targets retain **Copy** for manual use. Previewing or selecting text never applies
an edit. The illustrated example uses a supported editable selection.
Polishing preserves the input language by default. Prompt editing and hot reload
remain part of the independent extension source. MessageHelper-Upwork is retired
from current listings; its published ZIPs remain immutable historical downloads.

MacHelper honors Electron compatibility preferences saved in earlier versions.
With a saved opt-in, an unreadable selection can prompt MacHelper to request
full Accessibility from the supporting editor. If the toolbar misses the first
gesture in a new VS Code window, wait a few seconds and select the text again.
VS Code may enter Screen Reader Optimized mode, affecting folding and the
minimap. Apply still requires a verified edit target.

## Files

- `index.html`, `styles.css`, `app.js`: buildless responsive interface.
- `i18n.js`, `locales.js`: language detection, saved selection, safe text rendering,
  and authored shared interface translations. Extension descriptions and their
  translations live in each extension’s `discovery.json`.
- `registry.json`: approved public GitHub extension-folder links pinned to full
  commits. This file holds the marketplace's active extension entries.
  `github_registry.py` validates the links and reads the source during publication.
- `marketplace/preview.json` in each extension: optional preview layout,
  localized sample text, and links to the extension’s artwork, including icons
  and still illustrations.
- `assets/`: shared MacHelper artwork.
- The collection cards and the **Overview** tabs render previews supplied by
  their extensions. The homepage hero uses the first usable preview in registry
  order. The setup steps and source-folder illustration apply to any extension.
- Both previews loop in CSS over nine seconds. A shared visibility observer
  starts each at 20% visibility and suspends it offscreen, in hidden tabs, or
  behind a dialog. Each preview has an accessible summary. Visitors who prefer
  reduced motion see the completed example immediately.
- `marketplace.config.json`: site-wide settings, including the public URL,
  and MacHelper download metadata.
- [Legacy marketplace packages](../legacy/MarketplacePackages/packages/) contain
  immutable published source files and ZIPs outside the website source. The
  build serves the archived bytes at their original `/packages/` URLs for old
  catalogs and existing download links. This includes the
  original Translation 4.1.0, 4.2.0, 4.3.0, and 4.4.0 source/ZIP inventories and the
  MessageHelper-Upwork 1.3.0, 1.3.1, and 1.4.0 ZIPs. Translation 4.1.0's
  retained ZIP SHA-256 is `3f2f881578751ddcf445fc868212db96819c068369d786c29f72acd3c602be75`.
- `build.py`: reads approved extension manifests, builds the website listing,
  discovery index, and GitHub-backed installation catalog, and packages the
  prebuilt MacHelper app in `dist/`. The `PUBLIC_DOCUMENTS` allowlist publishes
  the AI extension guide and its references. `developer-guide.html` displays
  escaped Markdown, with the original `.md` available as a download.
- `discovery.py`: validates extension-owned `discovery.json` files and publishes
  `discovery-index.json` plus its SHA-256/size/revision manifest without requiring
  an app build. The index contains descriptions, capabilities, example queries,
  keywords, limitations, platforms, and translations, with stable manifest IDs,
  names, summaries, versions, and runtimes. It contains no code, source inventory,
  source download URLs, or images. `build.py` uses the same generator.
- `discovery_test.py`: strict descriptor validation, source-free index integrity,
  stable content revisions, browser identity, and explicit legacy import checks.
- `verify.py`: checks the published inventory, catalog links, historical
  package hashes, and MacHelper archive metadata and executable permissions.
  It checks the public document bytes and excludes the private
  `AI_DEPLOYMENT.md` runbook from the public output.
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

Changing language updates navigation, explanations, search/filter labels,
localized tool descriptions, access notices, installation steps, errors, and
an open detail dialog. Search matches both translated and original metadata;
category/platform values, filter selections, package URLs, and tool names stay
stable. Arabic uses right-to-left reading order. Text inside animated and SVG
previews follows the selected language, including the labels, captions,
accessible descriptions, and sample results. The Polish-input example uses
a draft and a revision in the same language.

The technical AI guide and its downloadable reference documents remain English
and are labelled accordingly. Source code, prompts, model IDs, and user data are
not translated. Unknown third-party metadata retains its original text. Add new
interface copy to the shared catalogs in `locales.js` and each tool’s metadata
translations to its `discovery.json`. Preview captions, accessible descriptions,
and sample text belong in the extension’s `marketplace/preview.json`. A preview
uses its English text when it has no translation for the current language.
Each animated instance has its own accessible IDs and updates on language
changes. The examples use authored samples without accessing AI, apps, user
drafts, or the clipboard. Use localized copy and check long strings and Arabic
layout. For still illustrations, provide language-specific files when the
artwork contains visible text. Translate captions and accessible descriptions
in the preview descriptor.
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

For frontend-only development, `build.py --without-app` omits the app ZIP.
Add `--local-sources` to test unpublished changes to first-party extension
folders, and pass the same flag to `verify.py`. This mode is for browsing and
previewing unpublished files. Use the default pinned GitHub sources when
testing installation against the reviewed release or preparing a deployment.
When both bundled tools come from the same published commit, pass that revision
to `scripts/build-apps.py --source-ref` to pin the app’s bundled catalog as well.
Serve `dist/` locally to test both the domain root and a mounted path prefix.

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

## Publish a tool

1. Put a complete MacHelper source package in a public GitHub repository.
   Include `extension.json`, `discovery.json`, `README.md`, and `LICENSE` in
   the package root. The package can live at the root of the repository or
   in a subfolder. Add website-only previews and artwork under `marketplace/`
   alongside the package files.
2. Push the source to an exact commit and submit its folder permalink for
   review. An approved entry in `registry.json` is a single URL inside the
   `extensions` array of the schema-1 registry. Use
   `https://github.com/OWNER/REPO/tree/FULL_COMMIT` with an optional subfolder.
   `FULL_COMMIT` is the 40-character Git commit ID.
3. Build and verify the marketplace. The publishing job reads the pinned
   manifests, package files, and preview, then generates the website listing,
   discovery index, and installation catalog. The site serves those generated
   files. Browsing and keyword or AI discovery use the published metadata
   without querying GitHub per listing.
4. When someone chooses **Add to MacHelper**, MacHelper opens the native
   permission review. After approval it downloads the package from direct
   GitHub HTTPS URLs, verifies sizes and hashes, and installs it atomically.
   Existing local copies keep their edits and preferences.

For a tool update, submit the new commit URL. Increment the manifest version
when installable files change so MacHelper can identify it as a newer release.
The MacHelper **Update…** action verifies the published source inventory and
keeps a backup of the previous source. Update an illustrated preview independently
when the source inventory has the same paths and bytes. Keep earlier source
revisions and release assets available. To retire a listing, remove its
registry entry. The marketplace keeps already published `/packages/` links
available. New registry entries use GitHub for source downloads. A temporary
GitHub outage can delay new installs while the last published listings remain
available.

### Author a preview

An extension can supply `marketplace/preview.json` with `schemaVersion: 1`,
a `layout`, and `strings` keyed by language. Provide a complete `en` table
and add translations for other supported languages. The website supplies
layout, timing, and reduced-motion behavior. The browser renders publisher
strings as text. Publishers supply data and image assets.

| Layout | English string keys |
| --- | --- |
| `lookup` | `description`, `editorTitle`, `documentHeading`, `sentenceBefore`, `word`, `sentenceAfter`, `meaningLabel`, `meaning`, `sentenceLabel`, `sentenceTranslation`, `settings`, `copy`, `selectStep`, `reviewStep`, `resultStep` |
| `revision` | `description`, `editorTitle`, `draft`, `result`, `resultLabel`, `settings`, `copy`, `apply`, `selectStep`, `reviewStep`, `resultStep` |
| `image` | `description` and optional `caption`. This layout also requires an `image` path. |

Optional `category` and `icon` fields customize the listing. Animated
layouts can also declare `fallbackImage` for use when the animated preview
cannot render. Set it to a single filename for language-independent artwork
or to a language-to-filename map with an `en` entry. The site uses the matching
file or the English file when a language is missing.

Paths in `icon`, `image`, and `fallbackImage` are relative to the extension’s
`marketplace/` folder. The publisher resolves them to URLs at the approved
GitHub commit. The browser loads the illustrated asset from GitHub.

Set `slug` to choose a stable detail URL. The default uses the extension
identifier with dots replaced by hyphens. For a separate manual ZIP download,
set `releaseZip` to the exact `.macsource.zip` asset name under the GitHub
release tag `v<VERSION>`. The author publishes and retains that ZIP. MacHelper
installation continues to use the verified source-file inventory.

A listing can use the static PNG declared by `extension.json` when `marketplace/preview.json` omits its icon. The publisher includes the PNG in the verified source inventory and uses its pinned GitHub URL.

For example, place `preview.png` beside the following `preview.json`:

```json
{
  "schemaVersion": 1,
  "layout": "image",
  "image": "preview.png",
  "strings": {
    "en": { "description": "A selected phrase and its suggested revision." }
  }
}
```

An extension without preview data still gets a card and details from its
manifest and discovery metadata. See the authored previews for the
[lookup layout](../Extensions/Translation/marketplace/preview.json) and
[revision layout](../Extensions/Polish-input/marketplace/preview.json).
Website assets under `marketplace/` are outside the MacHelper install
inventory.

## Unified source runtimes

MacHelper 6 reads `runtime: "javascript"` or `"native"` from the schema-2
manifest. Both runtimes use the same Open MacHelper link and complete
source-file catalog. Native source requires a `.swift` entry and
`native.execute`. Its detail and install pages explain the compiler requirement
and trusted native execution. Translation and Polish-input use JavaScript.

The authoring section and AI guide describe both adapters and migration with a stable identifier/settings. The public-document allowlist includes `docs/Native-Extensions.md`; a separate explicit mapping publishes `MacHelper/NativeExtensionSDK/MacHelperNativeSDK.swift` at `NativeExtensionSDK/MacHelperNativeSDK.swift`. The MacHelper download must bundle these exact public bytes. `AI_DEPLOYMENT.md` remains excluded from the website, source ZIPs, and app ZIP.

Check native catalog support using an isolated synthetic website/package fixture:

```sh
python3 -m unittest discover -s ExtensionMarket-website -p '*_test.py' -v
```

These checks validate website output and the source inventory. Test native
worker execution and hot reload with the host integration suite. New listings
and updates enter the registry through maintainer review.

## Description search and local discovery

Users can choose **Keywords** for ordinary text matching or **Describe your
need** for an explicit AI search. Keyword matching includes original and
localized descriptions, capabilities, examples, and keywords. Category and
platform filters apply to either mode. AI cards show a good/partial fit and a
reason; a no-match result explains when the catalog has no suitable tool.
Descriptions are untrusted data, and reasons are displayed as plain text. Only
real current catalog IDs can become result cards. Search never installs a tool.

The description form shows only the need text box and **Find with AI**. Progress,
**Cancel search**, errors, and connection-recovery actions appear when relevant;
successful searches use the normal result cards. Example queries remain public
search metadata, while model/revision/cache fields remain in the response
contract without adding static form text or a success-status header.

MacHelper’s local service bundles an initial lightweight discovery snapshot,
refreshes its metadata cache from the public manifest/index, and keeps the last
valid snapshot when an update is unavailable. Only descriptions are cached for discovery. Full tool
source is downloaded after the separate installation review. Index revisions
hash canonical entry JSON; the manifest also hashes the exact index bytes.
Update checks do not consume AI usage. Finding with AI sends the user's request
and relevant public metadata to their configured provider. It uses no marketplace
AI account, API key, or hosted AI service. Provider availability and limits apply.

MacHelper automatically starts a discovery-only HTTP service at
`http://127.0.0.1:43827` while the app is running and enabled. Enter a need and choose **Find with
AI**. That one click validates input, checks/creates the local connection when
necessary, and searches using MacHelper’s saved AI settings. Blank, oversized,
or otherwise invalid needs make no local request. Chrome/Edge may ask for
permission to access the local/loopback connection during the first valid
search. The status/session handshake itself does not run inference.

There is no separate Connect/Reconnect control. A new page, expired/evicted
session, app restart, pause and resume, or **AI Connection → Restart Connection** is handled by
the next valid **Find with AI** action. If a search receives HTTP 401 before
inference, it performs one new handshake and retries that search once. A second
401, provider failure, busy response, network timeout, or other AI error ends
the action without automatic inference retry. **Cancel search** cancels the
owned request and ignores late responses; leaving the page abandons its search.

The service accepts only the exact HTTPS marketplace Origin and loopback Host,
validates bounded requests, and requires the session’s Bearer token for
search/cancel. Its API exposes no arbitrary AI prompt, settings, files, shell
command, or installation operation. Queries, results, and tokens stay in memory,
not browser local storage or URLs. See the
[HTTP protocol](../docs/MacHelper-Protocol.md#website-local-discovery-machelper-65).

After a local connection error, **Open MacHelper** uses `machelper://open` to
launch/focus the app without AI, and **Get MacHelper** offers the download. The
website shows the same connection error if MacHelper is closed, missing, or
paused. Resume a paused app in **General → Enable MacHelper**, then choose
**Find with AI** again. Denied local access needs
approval in browser site settings. Resolve the issue and choose **Find with AI**
again. Keyword filtering always remains available.

Chrome or Edge can be installed before or after MacHelper. Reinstalling a browser
or creating a new profile requires no browser extension or native-host setup for
this search service; local-access approval and a fresh session may be needed.
MacHelper must be running, while its settings window can stay closed. Search and
its results remain on the website. The former Connector is retired from current
listings; previously published ZIPs remain available as immutable historical
downloads. MessageHelper-Upwork is also retired in favor of Translation and
Polish-input, which work across supported Mac apps without browser extensions.

The production service rejects localhost preview origins. Automated frontend
tests mock the local HTTP API; manual previews can use keyword filtering. Do not
weaken the origin check or ask users to disable browser security for testing.
The website’s Nginx Content Security Policy allows only same-origin connections
and `http://127.0.0.1:43827` for this local service; deploy that exact
`connect-src` rule with the client. No local-access request is made during page
load, language changes, query edits, or preview playback. Local-service tests
cover real loopback framing and mocked inference separately from any
usage-consuming live provider test. On a Mac with MacHelper running,
`python3 scripts/test-marketplace-service.py` checks the connection without AI;
add `--live` for one synthetic public ranking request using provider usage.

A standalone seed build (metadata only, with no app or source downloads) is:

```sh
python3 ExtensionMarket-website/discovery.py --output /tmp/machelper-discovery
```

App packaging runs this generator before bundling its initial snapshot, avoiding
an app-download/site-build dependency cycle. A release site build then includes
the same metadata revision together with the independently built app ZIP.
