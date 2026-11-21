# ExtensionMarket Docker deployment

The canonical public site is **https://local-ai-extension.nelson007.com/**. Build browser asset, catalog, source-package, and MacHelper download links relative to this root. A dedicated Caddy HTTPS site proxies directly to `extension-market:8080` without stripping a path prefix.

The old `https://recite.nelson007.com/extension-market` and trailing-slash landing URLs redirect to the new root with HTTP 308, preserving their query strings. Nested old paths remain direct HTTP 200 compatibility aliases for assets, catalogs, packages, and downloads. MacHelper rejects redirected source downloads, so those aliases must remain proxies rather than blanket redirects.

Retain previously published versioned source files and package archives in the built public output with their original bytes and hashes. A compatibility proxy cannot satisfy a pinned old catalog entry if its files have been removed or overwritten. The latest catalog can advertise a newer tool while those historical download URLs remain available.

This follows Serenity's existing SSH → server Docker build → Docker Hub push workflow. The static service has its own image, application container, release folders, and loopback health port. It shares the existing Docker network and Caddy proxy, while leaving Serenity's application containers, database, environment, and API credentials separate. This script updates that existing infrastructure; it does not provision a new server, DNS, Docker, Caddy, or SSH/registry credentials.

## Prepare and review

Build the website into `ExtensionMarket-website/dist/` from the pinned public GitHub registry. The build includes the generated catalogs, historical source packages, and the MacHelper ZIP produced by the app build. The Docker image receives `Dockerfile`, `nginx.conf`, and `dist/`. Keep private configuration outside that build context. Use the default GitHub source mode for deployment.

```sh
python3 scripts/build-apps.py
python3 ExtensionMarket-website/build.py
python3 ExtensionMarket-website/verify.py
node --test ExtensionMarket-website/test.cjs
python3 -m unittest discover -s ExtensionMarket-website -p build_test.py -v
python3 -m unittest discover -s test -p marketplace_deploy_test.py -v
```

```sh
python3 ExtensionMarket-website/deploy.py
# Equivalent explicit plan:
python3 ExtensionMarket-website/deploy.py --dry-run
```

Dry-run is the default and makes no SSH, registry, container, or proxy changes. It reports the public URL, image tag, SSH alias, release location, and bounded build-context size. Review the complete built output before deploying: everything under `dist/` is public. Hidden files and symlinks are rejected. App resources and published guide/SDK bytes must match the current source; the verifier rejects stale bundled documentation. Private deployment notes, user preferences, and credentials must remain outside the public output.

Committing or pushing this repository does not run a deployment. The version in `marketplace.config.json` is the build target, rather than proof of the currently hosted app version. Inspect the live `/data/extensions.json` metadata and the deployment result when checking which release is public. A website rollout also does not replace an app already installed on a user's Mac.

The default SSH alias is `voca-server`; the default public origin is `https://local-ai-extension.nelson007.com`. Its DNS must point to the existing server before rollout. Caddy obtains and renews TLS through its existing persistent certificate storage. Existing key-based SSH must work with `BatchMode=yes`. Registry settings are read from the private, Git-ignored ReciteVocabulary `.env` outside this repository. Use `--credentials-file` or `--ssh-alias` to select another existing local configuration. The script reads only the registry account/credential and SSH alias fields, never transfers that configuration, and sends any registry password through login stdin. It does not place credentials in image layers, build arguments, command arguments, logs, or environment files.

Each actual deployment first establishes one private SSH ControlMaster in a short, temporary directory with mode `0700`. It uses normal host-key/key configuration, batch authentication, a 60-second idle lifetime, and 15-second keepalives. Only this command-free connection setup may retry, at most three times, before creating a server lock or release. Every deployment stage and lock cleanup reuses that socket; a lost master fails closed instead of silently opening a new TCP connection. Remote commands are never automatically retried. The master closes after lock cleanup, and its temporary directory is removed even when a stage fails. Desktop/shared SSH control sockets are not used.

The production image builds on the existing Linux amd64 Docker server; local Docker Desktop is not needed for this SSH deployment workflow. A local static-container check requires a working Docker installation and can use:

```sh
docker build -t extension-market-website:local ExtensionMarket-website
docker run --rm --name extension-market-local \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1:3011:8080 extension-market-website:local
```

The image runs as UID/GID 101, listens on 8080, writes only to `/tmp`, and exposes `/healthz`. Stop the local test container when finished; do not prune unrelated containers or volumes.

## Deploy explicitly

```sh
python3 ExtensionMarket-website/deploy.py --deploy
```

An optional `--tag YYYYMMDDHHMMSS_GITCOMMIT` selects a release explicitly. Otherwise the script combines the UTC timestamp with the current Git commit. Images use `nelsonlin2023/extension-market-website:<tag>` through the configured Docker Hub account. Uncommitted build output is the content actually deployed; the commit label identifies the source checkout and does not replace reviewing that output.

The deployment creates `/root/extension-market/releases/<tag>/`, builds from its isolated `build/` directory, verifies a temporary candidate container, then pushes the image. It preserves source timestamps during transfer and builds with `--no-cache`. Before publishing or replacing the live container, it checks every candidate public file against a SHA-256 inventory prepared from the release files and matched to the local build. The inventory is saved privately alongside the deployment journal. This catches mixed old/new files caused by Docker context synchronization. The service is `extension-market` on `voca-net`, with `127.0.0.1:3011 → 8080`, restart policy `unless-stopped`, bounded Docker logs, a read-only filesystem, dropped capabilities, and no privilege escalation. It is limited to 128 MiB memory, one CPU, and 64 processes. Existing ExtensionMarket containers are retained under a release-specific rollback name. Container names owned by another deployment and occupied unrelated ports are rejected.

Before rollout, **https://recite.nelson007.com/en** and **https://recite.nelson007.com/serenity/health/live** must return 200. This legacy baseline origin stays fixed independently of the marketplace domain. The script derives its route migration from the live `/root/sourcecode/Deployment/Caddyfile`, preserves unrelated routes/sites, and refuses operator edits or conflicting target-domain configurations. It keeps the old nested-path proxy and replaces only the two legacy landing routes, then adds the dedicated canonical site. A private candidate is copied into the existing Caddy container and validated before the live file changes. The live bind-mounted file is written in place to preserve its inode, then Caddy reloads gracefully. Caddy and the vocabulary/Serenity services are not restarted.

The script permits up to 120 seconds for the new domain's first TLS certificate and health response, with short per-request timeouts. It then verifies the exact deployed root homepage, query-preserving legacy landing redirects, a direct legacy catalog alias, and both existing service routes. Config changes made concurrently by another operator are preserved. The full per-file candidate SHA-256 gate still runs before publishing or replacing the website. Public download/catalog verification and browser layout checks should accompany deployment of changed marketplace content.

## Rollback and retained state

Each release retains its `Caddyfile.before`, `Caddyfile.candidate`, private operation logs, and `deployment.json`. Credentials and runtime service environments are not included. The deployment attempts to restore the previous website container and Caddy config if activation fails.

To review a rollback plan, then roll back the currently active release:

```sh
python3 ExtensionMarket-website/deploy.py --rollback DEPLOYED_TAG
python3 ExtensionMarket-website/deploy.py --rollback DEPLOYED_TAG --deploy
```

Rollback checks the active container's release label and refuses to overwrite concurrent Caddy edits. The old container is restored with its previous running/stopped state; on a first deployment, rollback removes the new website and restores the previous route configuration. Existing service health is checked again.

Do not delete Docker volumes, prune the server globally, remove Serenity rollback containers, or replace Caddy's certificate/config volumes. Retained ExtensionMarket releases/images can be removed separately after a deliberate retention decision. If a process is forcibly killed, review the journal and container state before removing a stale `/root/extension-market/.deploy-lock`; an active deployment uses that lock to protect its transaction.


## Language assets

The same static deployment serves all 13 interface languages. `build.py` copies
`locales.js` and `i18n.js` alongside `app.js`; no server-side language service,
extra container, or AI connection is needed. Publish these assets and the HTML
from the same verified build so the selector and translations agree. Visitor
language preferences stay in browser local storage. The technical authoring guide
continues to be served in English with its original code and prompts intact.


## Discovery metadata and local app connection

Publish `discovery-index.json` and `discovery-manifest.json` from the same
verified build as `data/extensions.json` and `catalog.json`. The discovery
metadata contains descriptions and related listing data. The discovery
manifest’s SHA-256 and size must match the exact index bytes. Existing no-cache responses let MacHelper check
for a new revision without downloading extension source or making an AI call.
A failed update keeps the last valid app snapshot/cache. Do not hand-edit the
index, manifest, or generated website data; edit each tool's `discovery.json`
and rebuild. Previously published versioned source files remain immutable.

The optional website AI search connects directly to the running MacHelper 6.5
app on the visitor’s Mac at `http://127.0.0.1:43827`. No AI backend, provider
credential, or additional server container is deployed. That listener runs only
on the user’s IPv4 loopback interface; the marketplace server continues to serve
static HTTPS assets. Do not expose its port through Docker, Caddy, a LAN
interface, or a public firewall rule. The shipped Nginx Content Security Policy
permits `connect-src 'self' http://127.0.0.1:43827`; publish that exact rule with
the new client so browser CSP does not block the connection before local-access
approval. This requires no new Caddy route or exposed server port.

The website starts local requests only from a valid **Find with AI** click. It
validates the need first, checks/creates an expiring in-memory session when
necessary, and sends the bounded search with that session’s Bearer token.
Invalid input, page load, query edits, language changes, and demos never contact
the local service. Browser local/loopback network approval may appear on the
first valid search; the status/session handshake itself does not use AI. There
is no separate Connect/Reconnect control. An HTTP 401 rejection before inference
permits one handshake/search retry; other AI/provider errors are not retried.
The local service accepts only `https://local-ai-extension.nelson007.com`, with strict Origin,
Host, CORS, method/header/body validation and no generic AI/files/settings API.
A browser installed after MacHelper or reinstalled later can connect without
installing a search extension; local approval/session setup may repeat.

Local previews use keyword filtering or a mocked local HTTP API for automated
tests. Do not widen the production origin check, add wildcard CORS, or disable
browser local-access protections for preview convenience. After a connection
error, **Open MacHelper** uses `machelper://open` without starting AI, and
**Get MacHelper** offers the download. An unreachable service cannot distinguish
a closed app from a missing installation; do not report the app as uninstalled. MacHelper has no search screen or
native search-prefill link. Searching never installs or executes matched tools.
The existing deployment per-file checksum gate covers the public discovery
files, catalog, and historical packages as ordinary static assets. During the build,
the registry publisher reads the pinned GitHub files. MacHelper verifies files
downloaded from those URLs on install. The browser can load published preview
images from the exact GitHub raw content host.

On a Mac with the installed MacHelper running,
`python3 scripts/test-marketplace-service.py` checks the HTTP connection and
request rejection without using AI. Add `--live` for a synthetic public ranking
check that uses the saved provider and consumes its usage. These client checks
run on the Mac, independently of the static Linux container; keep browser and
local-service verification separate from server rollout health checks.
