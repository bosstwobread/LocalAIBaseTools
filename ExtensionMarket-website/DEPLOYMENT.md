# ExtensionMarket Docker deployment

The public site uses **https://recite.nelson007.com/extension-market/**. Build all browser asset, catalog, source-package, and MacHelper download links with the `/extension-market/` base. The existing Caddy HTTPS service strips that prefix and forwards only this route to `extension-market:8080`.

This follows Serenity's existing SSH → server Docker build → Docker Hub push workflow. The new static service has its own image, container, release folders, and loopback health port. It does not use Serenity's environment, database, API credentials, or containers.

## Prepare and review

Build the website into `ExtensionMarket-website/dist/` first, including the public catalog/source packages and the MacHelper ZIP produced by the project build. The Docker image receives only `Dockerfile`, `nginx.conf`, and `dist/`; private configuration and the rest of the repository are excluded.

```sh
python3 scripts/build-apps.py
python3 ExtensionMarket-website/build.py
```

```sh
python3 ExtensionMarket-website/deploy.py
# Equivalent explicit plan:
python3 ExtensionMarket-website/deploy.py --dry-run
```

Dry-run is the default and makes no SSH, registry, container, or proxy changes. It reports the public URL, image tag, SSH alias, release location, and bounded build-context size. Review the complete built output before deploying: everything under `dist/` is public. Hidden files and symlinks are rejected.

The default SSH alias is `voca-server`; the default public origin is `https://recite.nelson007.com`. Existing key-based SSH must work with `BatchMode=yes`. Registry settings are read from the private, Git-ignored ReciteVocabulary `.env` outside this repository. Use `--credentials-file` or `--ssh-alias` to select another existing local configuration. The script reads only the registry account/credential and SSH alias fields, never transfers that configuration, and sends any registry password through login stdin. It does not place credentials in image layers, build arguments, command arguments, logs, or environment files.

Local Docker Desktop is already available. The production build runs on the existing Linux amd64 Docker server, so the Mac's arm64 architecture does not affect the production image. A local static-container check can use:

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

The deployment creates `/root/extension-market/releases/<tag>/`, builds from its isolated `build/` directory, verifies a temporary candidate container, then pushes the image. The service is `extension-market` on `voca-net`, with `127.0.0.1:3011 → 8080`, restart policy `unless-stopped`, bounded Docker logs, a read-only filesystem, dropped capabilities, and no privilege escalation. It is limited to 128 MiB memory, one CPU, and 64 processes. Existing ExtensionMarket containers are retained under a release-specific rollback name. Container names owned by another deployment and occupied unrelated ports are rejected.

Before rollout, `/en` and `/serenity/health/live` must return 200. The script derives its minimal route addition from the live `/root/sourcecode/Deployment/Caddyfile`. It refuses to replace a different existing ExtensionMarket route. A private candidate is copied into the existing Caddy container and validated before the live file changes. The live bind-mounted file is written in place to preserve its inode, then Caddy reloads gracefully. Caddy and the vocabulary/Serenity services are not restarted.

The script verifies the website health path, the exact deployed homepage content, and the two existing service routes afterward. Config changes made concurrently by another operator are preserved. Public download/catalog verification and browser layout checks should accompany deployment of changed marketplace content.

## Rollback and retained state

Each release retains its `Caddyfile.before`, `Caddyfile.candidate`, private operation logs, and `deployment.json`. Credentials and runtime service environments are not included. The deployment attempts to restore the previous website container and Caddy config if activation fails.

To review a rollback plan, then roll back the currently active release:

```sh
python3 ExtensionMarket-website/deploy.py --rollback DEPLOYED_TAG
python3 ExtensionMarket-website/deploy.py --rollback DEPLOYED_TAG --deploy
```

Rollback checks the active container's release label and refuses to overwrite concurrent Caddy edits. The old container is restored with its previous running/stopped state; on a first deployment, rollback removes the new website and restores the previous route configuration. Existing service health is checked again.

Do not delete Docker volumes, prune the server globally, remove Serenity rollback containers, or replace Caddy's certificate/config volumes. Retained ExtensionMarket releases/images can be removed separately after a deliberate retention decision. If a process is forcibly killed, review the journal and container state before removing a stale `/root/extension-market/.deploy-lock`; an active deployment uses that lock to protect its transaction.
