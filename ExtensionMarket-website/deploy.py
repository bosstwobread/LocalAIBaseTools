#!/usr/bin/env python3
"""Plan by default; --deploy publishes an isolated Docker service over SSH.

The only build-context files transferred are Dockerfile, nginx.conf, and dist/.
Private registry settings stay outside this repository and use login stdin.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import inspect
import io
import json
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tarfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
PRIVATE_SETTINGS = Path.home() / "Project/proginn/ReciteVocabulary/.env"
PUBLIC_ORIGIN = "https://recite.nelson007.com"
PREFIX = "/extension-market/"


def candidate_caddy(original: str, domain: str) -> str:
    """Insert one isolated path without replacing an existing operator route."""
    uncommented = "\n".join(line.split("#", 1)[0] for line in original.splitlines())
    if "/extension-market" in uncommented:
        redirect = re.findall(r"(?m)^\s*redir\s+/extension-market\s+/extension-market/\s+308\s*$", uncommented)
        handler = re.findall(r"handle_path\s+/extension-market/\*\s*\{\s*reverse_proxy\s+extension-market:8080\s*\}", uncommented)
        if len(redirect) == 1 and len(handler) == 1 and uncommented.count("/extension-market") == 3:
            return original
        raise ValueError("An existing ExtensionMarket route differs from the managed route; it was preserved.")
    site = re.compile(r"(?m)^[ \t]*" + re.escape(domain) + r"[ \t]*\{[ \t]*$")
    if len(list(site.finditer(original))) != 1:
        raise ValueError("The existing HTTPS site block could not be identified uniquely.")
    block = ("\n  # BEGIN LocalAIBaseTools ExtensionMarket\n"
             "  redir /extension-market /extension-market/ 308\n"
             "  handle_path /extension-market/* {\n"
             "    reverse_proxy extension-market:8080\n"
             "  }\n"
             "  # END LocalAIBaseTools ExtensionMarket")
    return site.sub(lambda match: match.group(0) + block, original, count=1)


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
def run(args,stage,cwd=None,allow_failure=False):
 result=subprocess.run(args,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=900)
 log=release/(stage+'.log');log.write_text(result.stdout);log.chmod(0o600)
 if result.returncode and not allow_failure:raise RuntimeError(stage+' failed; inspect the private release log.')
 return result
def inspect_container(name):
 result=subprocess.run(['docker','inspect',name],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
 return json.loads(result.stdout)[0] if result.returncode==0 else None
def get(url,expected=200,body=False):
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
 request=urllib.request.Request(url,headers={'Cache-Control':'no-cache','User-Agent':'ExtensionMarketDeploy/1'})
 with opener.open(request,timeout=10) as response:
  if response.status!=expected:raise RuntimeError('Unexpected HTTP status during verification.')
  data=response.read(2*1024*1024+1) if body else response.read(4096)
  if len(data)>2*1024*1024:raise RuntimeError('Verification response exceeds its limit.')
  return data
def baselines():
 for path in ['/en','/serenity/health/live']:get(cfg['origin']+path)
def health(url):
 for attempt in range(20):
  try:
   if get(url)!=b'ok\n':raise RuntimeError('Unexpected website health response.')
   return
  except Exception:
   if attempt==19:raise
   time.sleep(1)
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
 step('Building the isolated linux/amd64 static image')
 run(['docker','build','--build-arg','BUILD_REVISION='+cfg['revision'],'-t',cfg['image'],'.'],'docker-build',cwd=release/'build')
 name='extension-market-candidate-'+cfg['tag']
 common=['--read-only','--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=64m','--cap-drop','ALL','--security-opt','no-new-privileges','--user','101:101','--memory','128m','--cpus','1','--pids-limit','64','--network','voca-net','--log-opt','max-size=10m','--log-opt','max-file=3']
 try:
  run(['docker','run','-d','--name',name]+common+[cfg['image']],'candidate-start')
  for attempt in range(20):
   check=run(['docker','exec',name,'wget','-q','-O','-','http://127.0.0.1:8080/healthz'],'candidate-health',allow_failure=True)
   if check.returncode==0 and check.stdout=='ok\n':break
   if attempt==19:raise RuntimeError('The candidate static container failed health verification.')
   time.sleep(1)
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
 health(cfg['origin']+'/extension-market/healthz')
 if digest(get(cfg['origin']+'/extension-market/',body=True))!=cfg['indexSHA256']:
  raise RuntimeError('The public page does not match this release.')
 baselines()
 record={'status':'deployed','tag':cfg['tag'],'image':cfg['image'],'publicURL':cfg['origin']+'/extension-market/','previousContainer':previous,'previousRunning':previous_running,'caddyBeforeSHA256':digest(original),'caddyAfterSHA256':digest(candidate),'revision':cfg['revision']}
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
            info.size = path.stat().st_size
            info.mode = 0o644
            with path.open("rb") as content:
                bundle.addfile(info, content)
    return output.getvalue()


def remote(target: str, command: list[str], *, data: bytes | None = None, quiet: bool = False) -> None:
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", target, shlex.join(command)],
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
    parser.add_argument("--public-origin", default=PUBLIC_ORIGIN, help="Existing HTTPS origin; the path is /extension-market/.")
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
    revision = subprocess.check_output(["git", "-C", str(ROOT.parent), "rev-parse", "HEAD"], text=True).strip()
    tag = args.rollback or args.tag or (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d%H%M%S") + "-" + revision[:12])
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}", tag):
        raise ValueError("The release tag must be a safe Docker tag of at most 96 characters.")
    image = namespace + "/extension-market-website:" + tag
    files = [] if args.rollback else source_files(args.dist.absolute())
    config = {"tag": tag, "image": image, "revision": revision, "domain": origin.hostname,
              "origin": public_origin, "rollback": bool(args.rollback)}
    if files:
        config["indexSHA256"] = hashlib.sha256((args.dist / "index.html").read_bytes()).hexdigest()
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
    try:
        remote(target, ["python3", "-c", bootstrap, tag, lock_token, "rollback" if args.rollback else "publish"])
        if not args.rollback:
            remote(target, ["tar", "xzf", "-", "--no-same-owner", "-C", plan["releaseDirectory"] + "/build"], data=archive(files))
            password = settings.get("DOCKER_PASSWORD")
            if password:
                remote(target, ["docker", "login", "docker.io", "--username", namespace, "--password-stdin"],
                       data=(password + "\n").encode(), quiet=True)
        program = inspect.getsource(candidate_caddy) + "\n" + REMOTE_TRANSACTION
        # The remote program imports re after its pure helper is defined; name
        # resolution occurs when the helper runs, after that import.
        remote(target, ["python3", "-c", program, json.dumps(config, separators=(",", ":"))])
    finally:
        cleanup = """from pathlib import Path\nimport os,sys\nlock=Path('/root/extension-market/.deploy-lock')\nif (lock/'owner').is_file() and (lock/'owner').read_text()==sys.argv[1]:\n if (lock/'pid').is_file():\n  try:os.kill(int((lock/'pid').read_text()),0)\n  except ProcessLookupError:pass\n  else:raise RuntimeError('The remote transaction is still cleaning up; its lock was preserved.')\n  (lock/'pid').unlink()\n (lock/'owner').unlink();lock.rmdir()\n"""
        try:
            remote(target, ["python3", "-c", cleanup, lock_token], quiet=True)
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
