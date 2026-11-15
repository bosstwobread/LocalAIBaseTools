#!/usr/bin/env python3
"""Plan by default; --deploy publishes an isolated Docker service over SSH.

The only build-context files transferred are Dockerfile, nginx.conf, and dist/.
Private registry settings stay outside this repository and use login stdin.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import datetime as dt
import hashlib
import inspect
import io
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
PRIVATE_SETTINGS = Path.home() / "Project/proginn/ReciteVocabulary/.env"
PUBLIC_ORIGIN = "https://local-ai-extension.nelson007.com"
LEGACY_ORIGIN = "https://recite.nelson007.com"
PREFIX = "/"


def candidate_caddy(original: str, domain: str) -> str:
    """Migrate only owned market routes; preserve unrelated Caddy bytes."""
    legacy_domain = "recite.nelson007.com"
    if domain == legacy_domain or not re.fullmatch(r"[a-z0-9.-]+", domain):
        raise ValueError("Choose a dedicated canonical marketplace domain.")

    def code(value):
        return "\n".join(line.split("#", 1)[0] for line in value.splitlines())

    def tokens(value):
        return " ".join(code(value).split())

    def site_span(value, host):
        matches = list(re.finditer(r"(?m)^[ \t]*" + re.escape(host) + r"[ \t]*\{[ \t]*(?:#[^\n]*)?$", value))
        if not matches:
            if host in code(value):
                raise ValueError("The marketplace domain appears in an unexpected Caddy route; it was preserved.")
            return None
        if len(matches) != 1:
            raise ValueError("A Caddy site block is duplicated; no routes were changed.")
        opening = value.index("{", matches[0].start())
        depth, quoted, escaped, comment = 1, None, False, False
        for position in range(opening + 1, len(value)):
            char = value[position]
            if comment:
                if char == "\n": comment = False
            elif quoted:
                if escaped: escaped = False
                elif char == "\\" and quoted != "`": escaped = True
                elif char == quoted: quoted = None
            elif char == "#": comment = True
            elif char in ['"', "`"]: quoted = char
            elif char == "{": depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0: return matches[0].start(), opening + 1, position, position + 1
        raise ValueError("A Caddy site block is incomplete; no routes were changed.")

    legacy = site_span(original, legacy_domain)
    if legacy is None:
        raise ValueError("The existing legacy HTTPS site block is missing.")
    canonical = site_span(original, domain)
    canonical_site = domain + " {\n  encode gzip\n  reverse_proxy extension-market:8080\n}"
    if canonical and tokens(original[canonical[0]:canonical[3]]) != tokens(canonical_site):
        raise ValueError("The canonical domain has an unexpected existing Caddy configuration; it was preserved.")

    # Exact landing handlers precede the compatibility wildcard. handle_path
    # strips the old prefix; {uri} retains the remaining path and query string.
    managed = ("  # BEGIN LocalAIBaseTools ExtensionMarket\n"
               "  handle_path /extension-market {\n"
               "    redir https://" + domain + "{uri} 308\n"
               "  }\n"
               "  handle_path /extension-market/ {\n"
               "    redir https://" + domain + "{uri} 308\n"
               "  }\n"
               "  handle_path /extension-market/* {\n"
               "    reverse_proxy extension-market:8080\n"
               "  }\n"
               "  # END LocalAIBaseTools ExtensionMarket")
    previous = ("redir /extension-market /extension-market/ 308\n"
                "handle_path /extension-market/* { reverse_proxy extension-market:8080 }")
    body = original[legacy[1]:legacy[2]]
    marker = re.compile(r"(?ms)^[ \t]*# BEGIN LocalAIBaseTools ExtensionMarket[ \t]*\n.*?^[ \t]*# END LocalAIBaseTools ExtensionMarket[ \t]*(?=\n|$)")
    owned = list(marker.finditer(body))
    if len(owned) > 1:
        raise ValueError("The managed legacy route is duplicated; it was preserved.")
    if owned:
        match = owned[0]
        if tokens(match.group()) not in [tokens(previous), tokens(managed)]:
            raise ValueError("The existing managed legacy route was edited; it was preserved.")
        remainder = body[:match.start()] + body[match.end():]
        if "/extension-market" in code(remainder):
            raise ValueError("An additional legacy marketplace route was found; it was preserved.")
        body = body[:match.start()] + managed + body[match.end():]
    else:
        if "/extension-market" in code(body):
            raise ValueError("An unmanaged legacy marketplace route was found; it was preserved.")
        body = "\n" + managed + body
    result = original[:legacy[1]] + body + original[legacy[2]:]
    if canonical is None:
        result += ("" if result.endswith("\n") else "\n") + "\n" + canonical_site + "\n"
    return result


def public_manifest(folder: Path) -> dict:
    """Hash every extracted public file independently of Docker's caches."""
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError("The public output must be an ordinary directory.")
    result, total = {}, 0
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise ValueError("Public image verification does not permit symlinks.")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("Public image verification requires ordinary files.")
        relative = path.relative_to(folder).as_posix()
        if any(ord(char) < 32 or char == "\\" for char in relative):
            raise ValueError("A public filename cannot be represented safely in a checksum manifest.")
        sha, size = hashlib.sha256(), 0
        with path.open("rb") as content:
            for chunk in iter(lambda: content.read(64 * 1024), b""):
                size += len(chunk); total += len(chunk)
                if total > 512 * 1024 * 1024:
                    raise ValueError("The public output exceeds its verification size limit.")
                sha.update(chunk)
        result[relative] = {"sha256": sha.hexdigest(), "size": size}
        if len(result) > 2048:
            raise ValueError("The public output exceeds its verification file limit.")
    if "index.html" not in result:
        raise ValueError("The public verification manifest is missing index.html.")
    return result


def checksum_input(manifest: dict) -> str:
    lines = []
    for relative, record in sorted(manifest.items()):
        if (not relative or relative.startswith("/") or
                any(part in ["", ".", ".."] for part in relative.split("/")) or
                any(ord(char) < 32 or char == "\\" for char in relative) or
                not re.fullmatch(r"[0-9a-f]{64}", record["sha256"])):
            raise ValueError("The public checksum manifest contains an unsafe path or digest.")
        lines.append(record["sha256"] + "  /usr/share/nginx/html/" + relative + "\n")
    if not lines:
        raise ValueError("The public checksum manifest cannot be empty.")
    return "".join(lines)


def manifest_digest(manifest: dict) -> str:
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


# This program is sent over SSH, never copied into the Docker build context.
# All subprocess output is retained in private per-release logs instead of
# exposing runtime configuration, registry responses, or full proxy configs.
REMOTE_TRANSACTION = r'''
import atexit,hashlib,json,os,re,shutil,signal,subprocess,sys,time,urllib.request,urllib.error
from pathlib import Path

cfg=json.loads(sys.argv[1])
base=Path('/root/extension-market')
release=base/'releases'/cfg['tag']
live=Path('/root/sourcecode/Deployment/Caddyfile')
candidate_path=release/'Caddyfile.candidate'
backup=release/'Caddyfile.before'
journal=release/'deployment.json'
temporary='/tmp/extension-market-'+cfg['tag']+'.Caddyfile'
previous=None
previous_running=False
start_attempted=False
old_stopped=False
proxy_written=False
original=None
candidate=None
lock=base/'.deploy-lock'
(lock/'pid').write_text(str(os.getpid()))

def release_lock():
 try:
  if (lock/'owner').read_text()==cfg['lockToken']:
   (lock/'pid').unlink(missing_ok=True);(lock/'owner').unlink();lock.rmdir()
 except OSError:pass
def interrupted(*_):raise KeyboardInterrupt()
atexit.register(release_lock)
for number in [signal.SIGTERM,signal.SIGHUP,signal.SIGINT]:signal.signal(number,interrupted)

def step(message):print('STEP '+message,flush=True)
def digest(data):return hashlib.sha256(data).hexdigest()
def save_json(path,value):
 path.write_text(json.dumps(value,indent=2)+'\n');path.chmod(0o600)
def run(args,stage,cwd=None,allow_failure=False,input_text=None):
 result=subprocess.run(args,cwd=cwd,input=input_text,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=900)
 log=release/(stage+'.log');log.write_text(result.stdout);log.chmod(0o600)
 if result.returncode and not allow_failure:raise RuntimeError(stage+' failed; inspect the private release log.')
 return result
def inspect_container(name):
 result=subprocess.run(['docker','inspect',name],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
 return json.loads(result.stdout)[0] if result.returncode==0 else None
def get(url,expected=200,body=False,timeout=10,allow_redirects=True):
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
 if not allow_redirects:
  class NoRedirect(urllib.request.HTTPRedirectHandler):
   def redirect_request(self,*args,**kwargs):return None
  opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
 request=urllib.request.Request(url,headers={'Cache-Control':'no-cache','User-Agent':'ExtensionMarketDeploy/1'})
 with opener.open(request,timeout=timeout) as response:
  if response.status!=expected:raise RuntimeError('Unexpected HTTP status during verification.')
  data=response.read(2*1024*1024+1) if body else response.read(4096)
  if len(data)>2*1024*1024:raise RuntimeError('Verification response exceeds its limit.')
  return data
def baselines():
 for path in ['/en','/serenity/health/live']:get(cfg['legacyOrigin']+path)
def health(url,wait_seconds=20):
 deadline=time.monotonic()+wait_seconds
 while True:
  try:
   if get(url,timeout=min(3,max(.1,deadline-time.monotonic())))!=b'ok\n':raise RuntimeError('Unexpected website health response.')
   return
  except Exception:
   if time.monotonic()>=deadline:raise
   time.sleep(min(1,max(0,deadline-time.monotonic())))
def verify_legacy_routes(expected):
 for path in ['/extension-market','/extension-market/']:
  try:get(cfg['legacyOrigin']+path+'?from=compatibility',allow_redirects=False)
  except urllib.error.HTTPError as error:
   if error.code!=308 or error.headers.get('Location')!=cfg['origin']+'/?from=compatibility':
    raise RuntimeError('A legacy landing redirect did not preserve its query or canonical root.')
  else:raise RuntimeError('A legacy landing URL did not redirect to the canonical root.')
 if 'catalog.json' in expected:
  data=get(cfg['legacyOrigin']+'/extension-market/catalog.json',body=True,allow_redirects=False)
  if digest(data)!=expected['catalog.json']['sha256']:
   raise RuntimeError('The legacy native catalog alias does not serve the verified bytes directly.')
def write_in_place(data):
 with live.open('wb') as output:output.write(data);output.flush();os.fsync(output.fileno())
def reload_proxy():run(['docker','exec','caddy','caddy','reload','--config','/etc/caddy/Caddyfile','--adapter','caddyfile'],'caddy-reload')
def restore_proxy(before,after):
 current=live.read_bytes()
 if current==before:return
 if current!=after:raise RuntimeError('Concurrent Caddy edits detected; automatic config rollback did not overwrite them.')
 write_in_place(before);reload_proxy()
def rollback_runtime(old,was_running):
 if old:
  saved=inspect_container(old)
  if not saved or (saved['Config'].get('Labels') or {}).get('org.localaibasetools.service')!='extension-market':
   raise RuntimeError('The previous website container is unavailable; the current container was preserved.')
 current=inspect_container('extension-market')
 if current:
  if (current['Config'].get('Labels') or {}).get('org.localaibasetools.release')!=cfg['tag']:
   raise RuntimeError('The running website changed concurrently; automatic rollback preserved it.')
  run(['docker','rm','-f','extension-market'],'rollback-new-container')
 if old:
  run(['docker','rename',old,'extension-market'],'rollback-rename')
  if was_running:run(['docker','start','extension-market'],'rollback-start')

if cfg.get('rollback'):
 record=json.loads(journal.read_text())
 if record.get('status')!='deployed':raise RuntimeError('This release is not an active rollback candidate.')
 current=inspect_container('extension-market')
 if not current or (current['Config'].get('Labels') or {}).get('org.localaibasetools.release')!=cfg['tag']:
  raise RuntimeError('Only the currently deployed release can be rolled back by this command.')
 before=backup.read_bytes();after=candidate_path.read_bytes()
 if live.read_bytes() not in [before,after]:raise RuntimeError('Concurrent Caddy edits detected; rollback preserved them.')
 baselines()
 rollback_runtime(record.get('previousContainer'),record.get('previousRunning',False))
 restore_proxy(before,after)
 baselines()
 record['status']='rolled-back';save_json(journal,record)
 print(json.dumps({'status':'rolled-back','release':cfg['tag'],'previousContainerRestored':bool(record.get('previousContainer'))}),flush=True)
 sys.exit(0)

try:
 step('Checking server resources and existing services')
 if shutil.disk_usage('/').free<1024**3:raise RuntimeError('The server needs at least 1 GiB free before building.')
 architecture=run(['docker','info','--format','{{.Architecture}}'],'docker-architecture').stdout.strip()
 if architecture not in ['x86_64','amd64']:raise RuntimeError('This deployment expects the existing linux/amd64 Docker host.')
 run(['docker','network','inspect','voca-net'],'docker-network')
 caddy=inspect_container('caddy')
 if not caddy or not caddy['State']['Running']:raise RuntimeError('The existing Caddy service is not running.')
 mounts=[item for item in caddy['Mounts'] if item['Destination']=='/etc/caddy/Caddyfile']
 if len(mounts)!=1 or mounts[0]['Source']!=str(live):raise RuntimeError('The Caddy mount changed; deployment preserved it.')
 current=inspect_container('extension-market')
 if current and (current['Config'].get('Labels') or {}).get('org.localaibasetools.service')!='extension-market':
  raise RuntimeError('The extension-market container name belongs to another deployment; it was preserved.')
 listeners=subprocess.check_output(['ss','-ltnH'],text=True)
 if any(line.split()[3].endswith(':3011') for line in listeners.splitlines()) and not current:
  raise RuntimeError('Loopback port 3011 is already occupied; no service was changed.')
 baselines()
 original=live.read_bytes()
 candidate=candidate_caddy(original.decode('utf-8'),cfg['domain']).encode('utf-8')
 backup.write_bytes(original);backup.chmod(0o600)
 candidate_path.write_bytes(candidate);candidate_path.chmod(0o600)
 run(['docker','cp',str(candidate_path),'caddy:'+temporary],'caddy-candidate-copy')
 run(['docker','exec','caddy','caddy','validate','--config',temporary,'--adapter','caddyfile'],'caddy-validate')
 expected=public_manifest(release/'build'/'dist')
 if len(expected)!=cfg['publicFileCount'] or manifest_digest(expected)!=cfg['publicManifestSHA256']:
  raise RuntimeError('The extracted public files do not match the prepared local manifest; no image was published.')
 save_json(release/'public-files.sha256.json',expected)
 step('Building the isolated linux/amd64 static image')
 run(['docker','build','--no-cache','--build-arg','BUILD_REVISION='+cfg['revision'],'-t',cfg['image'],'.'],'docker-build',cwd=release/'build')
 name='extension-market-candidate-'+cfg['tag']
 common=['--read-only','--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=64m','--cap-drop','ALL','--security-opt','no-new-privileges','--user','101:101','--memory','128m','--cpus','1','--pids-limit','64','--network','voca-net','--log-opt','max-size=10m','--log-opt','max-file=3']
 try:
  run(['docker','run','-d','--name',name]+common+[cfg['image']],'candidate-start')
  for attempt in range(20):
   check=run(['docker','exec',name,'wget','-q','-O','-','http://127.0.0.1:8080/healthz'],'candidate-health',allow_failure=True)
   if check.returncode==0 and check.stdout=='ok\n':break
   if attempt==19:raise RuntimeError('The candidate static container failed health verification.')
   time.sleep(1)
  step('Verifying every public candidate file against the prepared SHA-256 manifest')
  run(['docker','exec','-i',name,'sha256sum','-c','-'],'candidate-integrity',input_text=checksum_input(expected))
 finally:
  run(['docker','rm','-f',name],'candidate-cleanup',allow_failure=True)
 step('Pushing the verified timestamped image')
 run(['docker','push',cfg['image']],'docker-push')
 if live.read_bytes()!=original:raise RuntimeError('Caddy changed during the build; no proxy edits were applied.')
 latest=inspect_container('extension-market')
 if bool(latest)!=bool(current) or (latest and current and (latest.get('Id')!=current.get('Id') or latest['State']['Running']!=current['State']['Running'])):
  raise RuntimeError('The website container changed during the build; the newer operator state was preserved.')
 step('Replacing only the ExtensionMarket container')
 if current:
  previous_name='extension-market-rollback-'+cfg['tag'];previous_running=current['State']['Running']
  run(['docker','stop','extension-market'],'previous-stop')
  old_stopped=True
  run(['docker','rename','extension-market',previous_name],'previous-rename')
  previous=previous_name
 start_attempted=True
 run(['docker','run','-d','--name','extension-market','--restart','unless-stopped','--label','org.localaibasetools.service=extension-market','--label','org.localaibasetools.release='+cfg['tag'],'-p','127.0.0.1:3011:8080']+common+[cfg['image']],'website-start')
 health('http://127.0.0.1:3011/healthz')
 if live.read_bytes()!=original:raise RuntimeError('Concurrent Caddy edits detected before activation.')
 if candidate!=original:
  step('Reloading the dedicated HTTPS path through Caddy')
  write_in_place(candidate);proxy_written=True;reload_proxy()
 health(cfg['origin']+'/healthz',wait_seconds=120)
 if digest(get(cfg['origin']+'/',body=True))!=cfg['indexSHA256']:
  raise RuntimeError('The public page does not match this release.')
 verify_legacy_routes(expected)
 baselines()
 record={'status':'deployed','tag':cfg['tag'],'image':cfg['image'],'publicURL':cfg['origin']+'/','previousContainer':previous,'previousRunning':previous_running,'caddyBeforeSHA256':digest(original),'caddyAfterSHA256':digest(candidate),'revision':cfg['revision'],'publicFileCount':len(expected),'publicManifestSHA256':manifest_digest(expected)}
 save_json(journal,record)
 print(json.dumps(record),flush=True)
except BaseException:
 rollback_errors=[]
 try:
  if start_attempted or previous:rollback_runtime(previous,previous_running)
  elif old_stopped and previous_running:run(['docker','start','extension-market'],'rollback-stopped-previous')
 except BaseException as error:rollback_errors.append(str(error))
 try:
  if proxy_written:restore_proxy(original,candidate)
 except BaseException as error:rollback_errors.append(str(error))
 try:save_json(journal,{'status':'failed','tag':cfg['tag'],'image':cfg['image'],'rollbackErrors':rollback_errors})
 except Exception:pass
 if rollback_errors:print(json.dumps({'rollbackErrors':rollback_errors}),flush=True)
 raise
finally:
 subprocess.run(['docker','exec','caddy','rm','-f',temporary],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
'''


def remote_program() -> str:
    # Helper annotations must not resolve Path before the remote imports run.
    return "from __future__ import annotations\n" + "\n".join(
        inspect.getsource(function) for function in
        [candidate_caddy, public_manifest, checksum_input, manifest_digest]
    ) + "\n" + REMOTE_TRANSACTION


def private_settings(path: Path) -> dict[str, str]:
    allowed = {"SERVER_SSH_ALIAS", "DOCKER_USERNAME", "DOCKER_PASSWORD", "DOCKER_REGISTRY"}
    values = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                if key.strip() in allowed:
                    values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def source_files(dist: Path) -> list[tuple[Path, str]]:
    if dist.is_symlink() or not dist.is_dir() or not (dist / "index.html").is_file():
        raise ValueError("Build the website first: dist/index.html is missing or the output directory is a symlink.")
    files = [(ROOT / "Dockerfile", "Dockerfile"), (ROOT / "nginx.conf", "nginx.conf")]
    if any(path.is_symlink() or not path.is_file() for path, _ in files):
        raise ValueError("The deployment Dockerfile and nginx configuration must be ordinary files.")
    for path in sorted(dist.rglob("*")):
        relative = path.relative_to(dist)
        if path.is_symlink() or any(part.startswith(".") for part in relative.parts):
            raise ValueError("The public dist folder must not contain symlinks or hidden/private files.")
        if path.is_file():
            files.append((path, "dist/" + relative.as_posix()))
        elif not path.is_dir():
            raise ValueError("Only ordinary public files and directories can enter the build context.")
    if len(files) > 2048 or sum(path.stat().st_size for path, _ in files) > 512 * 1024 * 1024:
        raise ValueError("The static build context exceeds its bounded file/size limit.")
    return files


def archive(files: list[tuple[Path, str]]) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as bundle:
        for path, name in files:
            if path.is_symlink() or not path.is_file():
                raise ValueError("A build-context file changed while preparing the archive.")
            info = tarfile.TarInfo(name)
            metadata = path.stat()
            info.size = metadata.st_size
            info.mode = 0o644
            # BuildKit's local-context sync can compare size/mtime metadata
            # before hashing file contents. Epoch-zero mtimes let same-size
            # JSON changes reuse stale context bytes, even with --no-cache.
            info.mtime = metadata.st_mtime_ns // 1_000_000_000
            info.pax_headers["mtime"] = f"{metadata.st_mtime_ns // 1_000_000_000}.{metadata.st_mtime_ns % 1_000_000_000:09d}"
            with path.open("rb") as content:
                bundle.addfile(info, content)
    return output.getvalue()


@contextmanager
def deployment_ssh(target: str):
    """One private authenticated connection; only command-free setup retries."""
    # A short path also fits macOS's Unix-domain socket length limit.
    with tempfile.TemporaryDirectory(prefix="market-ssh-", dir="/tmp") as directory:
        os.chmod(directory, 0o700)
        control = str(Path(directory) / "control")
        options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=1",
                   "-o", "ControlPath=" + control, "-o", "ControlPersist=60",
                   "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
        try:
            for attempt in range(3):
                try:
                    result = subprocess.run(["ssh", "-M", "-N", "-f", "-o", "ControlMaster=yes"] + options + [target],
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
                    if result.returncode == 0:
                        check = subprocess.run(["ssh", "-O", "check", "-o", "ControlMaster=no"] + options + [target],
                                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                        if check.returncode == 0:
                            break
                except subprocess.TimeoutExpired:
                    pass
                # This closes only our socket if setup partially succeeded.
                try:
                    subprocess.run(["ssh", "-O", "exit", "-o", "ControlMaster=no"] + options + [target],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                except (OSError, subprocess.SubprocessError):
                    pass
                if attempt == 2:
                    raise RuntimeError("Could not establish the private deployment SSH connection after three attempts; no remote command was run.")
                time.sleep(1)
            yield control
        finally:
            try:
                subprocess.run(["ssh", "-O", "exit", "-o", "ControlMaster=no"] + options + [target],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            except (OSError, subprocess.SubprocessError):
                # Preserve the original deployment/rollback exception.
                pass


def remote(target: str, command: list[str], *, data: bytes | None = None, quiet: bool = False,
           control_path: str | None = None) -> None:
    options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ControlMaster=no",
               "-o", "ControlPath=" + (control_path or "none")]
    if control_path:
        # Mux-only: if this master dies, do not silently establish a new TCP
        # connection and risk an ambiguous repeat of a deployment operation.
        options += ["-o", "ProxyCommand=false"]
    result = subprocess.run(["ssh"] + options + [target, shlex.join(command)],
                            input=data, stdout=subprocess.PIPE if quiet else None,
                            stderr=subprocess.PIPE if quiet else None)
    if result.returncode:
        raise RuntimeError("A private SSH/Docker operation failed; no credentials were logged." if quiet
                           else "The remote deployment operation failed; review its bounded release logs.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deploy", action="store_true", help="Actually build/push/deploy; omitted means dry-run.")
    parser.add_argument("--dry-run", action="store_true", help="Explicitly print the plan without SSH or Docker changes.")
    parser.add_argument("--credentials-file", type=Path, default=PRIVATE_SETTINGS, help="Private ReciteVocabulary .env; never transferred.")
    parser.add_argument("--ssh-alias", help="Existing key-authenticated SSH alias, defaulting to the private configuration.")
    parser.add_argument("--public-origin", default=PUBLIC_ORIGIN, help="Dedicated HTTPS marketplace origin, served at its root.")
    parser.add_argument("--dist", type=Path, default=ROOT / "dist", help="Built public static files, including source packages and MacHelper ZIP.")
    parser.add_argument("--tag", help="Optional explicit timestamp/commit image tag.")
    parser.add_argument("--rollback", metavar="DEPLOYED_TAG", help="Roll back this active release; still requires --deploy to act.")
    args = parser.parse_args()
    if args.deploy and args.dry_run:
        parser.error("Choose --deploy or --dry-run, not both.")
    settings = private_settings(args.credentials_file)
    target = args.ssh_alias or settings.get("SERVER_SSH_ALIAS", "voca-server")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}", target):
        raise ValueError("Choose a valid existing SSH alias.")
    namespace = settings.get("DOCKER_USERNAME", "nelsonlin2023")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", namespace):
        raise ValueError("The configured Docker Hub account name is invalid.")
    origin = urlsplit(args.public_origin)
    if origin.scheme != "https" or not origin.hostname or origin.username or origin.password or origin.path not in ["", "/"] or origin.query or origin.fragment or origin.port not in [None, 443]:
        raise ValueError("The public origin must be an existing HTTPS domain without a path or credentials.")
    public_origin = "https://" + origin.hostname
    if public_origin == LEGACY_ORIGIN:
        raise ValueError("Use the dedicated marketplace domain; the legacy vocabulary origin is preserved.")
    revision = subprocess.check_output(["git", "-C", str(ROOT.parent), "rev-parse", "HEAD"], text=True).strip()
    tag = args.rollback or args.tag or (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d%H%M%S") + "-" + revision[:12])
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}", tag):
        raise ValueError("The release tag must be a safe Docker tag of at most 96 characters.")
    image = namespace + "/extension-market-website:" + tag
    files = [] if args.rollback else source_files(args.dist.absolute())
    config = {"tag": tag, "image": image, "revision": revision, "domain": origin.hostname,
              "origin": public_origin, "legacyOrigin": LEGACY_ORIGIN, "rollback": bool(args.rollback)}
    if files:
        expected = public_manifest(args.dist.absolute())
        if len(expected) != len(files) - 2:
            raise ValueError("The public file inventory changed while preparing the deployment.")
        config["indexSHA256"] = expected["index.html"]["sha256"]
        config["publicFileCount"] = len(expected)
        config["publicManifestSHA256"] = manifest_digest(expected)
    plan = {"mode": "deploy" if args.deploy else "dry-run", "operation": "rollback" if args.rollback else "publish",
            "sshAlias": target, "image": image, "publicURL": public_origin + PREFIX,
            "releaseDirectory": "/root/extension-market/releases/" + tag,
            "container": "extension-market", "network": "voca-net", "loopbackPort": 3011,
            "buildContextFiles": len(files), "buildContextBytes": sum(path.stat().st_size for path, _ in files),
            "privateSettingsTransferred": False}
    print(json.dumps(plan, indent=2), flush=True)
    if not args.deploy:
        print("Dry-run only: no SSH, registry, containers, or proxy configuration changed.")
        return
    registry = settings.get("DOCKER_REGISTRY", "docker.io")
    if registry not in ["docker.io", "https://index.docker.io/v1/"]:
        raise ValueError("This deployment uses the existing Docker Hub workflow only.")
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    lock_token = tag + "-" + str(__import__("os").getpid())
    config["lockToken"] = lock_token
    bootstrap = """import os,sys\nfrom pathlib import Path\nbase=Path('/root/extension-market');base.mkdir(mode=0o700,exist_ok=True)\nlock=base/'.deploy-lock';lock.mkdir(mode=0o700)\n(lock/'owner').write_text(sys.argv[2])\nrelease=base/'releases'/sys.argv[1]\nif sys.argv[3]=='publish':\n release.mkdir(mode=0o700,parents=True,exist_ok=False)\n (release/'build').mkdir(mode=0o700)\nelif not (release/'deployment.json').is_file():\n raise RuntimeError('The rollback release was not found.')\n"""
    with deployment_ssh(target) as control:
        try:
            remote(target, ["python3", "-c", bootstrap, tag, lock_token, "rollback" if args.rollback else "publish"], control_path=control)
            if not args.rollback:
                remote(target, ["tar", "xzf", "-", "--no-same-owner", "-C", plan["releaseDirectory"] + "/build"], data=archive(files), control_path=control)
                password = settings.get("DOCKER_PASSWORD")
                if password:
                    remote(target, ["docker", "login", "docker.io", "--username", namespace, "--password-stdin"],
                           data=(password + "\n").encode(), quiet=True, control_path=control)
            remote(target, ["python3", "-c", remote_program(), json.dumps(config, separators=(",", ":"))], control_path=control)
        finally:
            cleanup = """from pathlib import Path\nimport os,sys\nlock=Path('/root/extension-market/.deploy-lock')\nif (lock/'owner').is_file() and (lock/'owner').read_text()==sys.argv[1]:\n if (lock/'pid').is_file():\n  try:os.kill(int((lock/'pid').read_text()),0)\n  except ProcessLookupError:pass\n  else:raise RuntimeError('The remote transaction is still cleaning up; its lock was preserved.')\n  (lock/'pid').unlink()\n (lock/'owner').unlink();lock.rmdir()\n"""
            try:
                remote(target, ["python3", "-c", cleanup, lock_token], quiet=True, control_path=control)
            except Exception:
                print("Deployment lock cleanup needs review on the server.", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Deployment interrupted; review the release journal before retrying.", file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
