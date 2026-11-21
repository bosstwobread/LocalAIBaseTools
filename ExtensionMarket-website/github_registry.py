"""Read approved GitHub extension folders without mirroring their source."""

import hashlib
import json
import os
import re
import ssl
import stat
import subprocess
import sys
import tempfile
from functools import cached_property, lru_cache
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener


MAX_REGISTRY = 1024 * 1024
MAX_FILES = 128
MAX_FILE_BYTES = 512 * 1024
MAX_PACKAGE_BYTES = 4 * 1024 * 1024
PATH_COMPONENT = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_. -]{0,119}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]{1,100}")
OWNER = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}")
COMMIT = re.compile(r"[a-f0-9]{40}")
LOCAL_REPOSITORY = ("bosstwobread", "localaibasetools")


def validate_path(path):
    parts = path.split("/")
    if len(path.encode("utf-8")) > 512 or len(parts) > 12 or not all(map(PATH_COMPONENT.fullmatch, parts)):
        raise ValueError("Invalid extension source path.")
    return parts


def include_runtime(path):
    parts = path.split("/")
    return parts[0].casefold() != "marketplace" and not any(
        part.startswith(".") or part.casefold() in {"node_modules", "__pycache__", "ai_deployment.md"} for part in parts
    )


def read_regular_file(path, maximum):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("Expected an ordinary file: " + path.name)
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("A file exceeds its size limit: " + path.name)
    return data


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@lru_cache(maxsize=1)
def github_opener():
    context = ssl.create_default_context()
    if sys.platform == "darwin" and not context.cert_store_stats()["x509_ca"]:
        context.load_verify_locations("/etc/ssl/cert.pem")
    return build_opener(HTTPSHandler(context=context), NoRedirect())


def fetch_raw(url, maximum):
    try:
        request = Request(url, headers={"User-Agent": "LocalAIBaseTools marketplace publisher"})
        with github_opener().open(request, timeout=15) as response:
            if response.status != 200 or response.geturl() != url:
                raise ValueError("Expected a direct GitHub raw file response.")
            data = response.read(maximum + 1)
    except (HTTPError, URLError) as error:
        raise ValueError("Unable to read a pinned GitHub file: " + url) from error
    if len(data) > maximum:
        raise ValueError("A GitHub file exceeds its size limit: " + url)
    return data


def read_git_tree(owner, repository, commit, path):
    # Fetch Git objects without blobs. Only the selected folder's needed files
    # are subsequently downloaded using their raw URLs.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")
    with tempfile.TemporaryDirectory(prefix="marketplace-git-") as temp:
        command = [
            "git", "-C", temp, "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
            "-c", "http.followRedirects=false", "-c", "credential.helper=",
            "-c", "core.hooksPath=" + os.devnull, "-c", "gc.auto=0",
        ]

        def run(args):
            return subprocess.run(command + args, env=env, capture_output=True, check=True, timeout=40)

        try:
            run(["init", "--bare", "--quiet"])
            remote = f"https://github.com/{owner}/{repository}.git"
            fetch = run(["fetch", "--quiet", "--depth=1", "--filter=blob:none", "--no-tags",
                         "--no-recurse-submodules", remote, commit])
            if b"filtering not recognized" in fetch.stderr or run(["rev-parse", "FETCH_HEAD"]).stdout.strip() != commit.encode():
                raise ValueError("GitHub did not return the requested filtered commit.")
            target = "FETCH_HEAD:" + path if path else "FETCH_HEAD"
            return run(["ls-tree", "-rtz", target]).stdout
        except (subprocess.SubprocessError, OSError) as error:
            raise ValueError(f"Unable to read the approved GitHub folder {owner}/{repository}@{commit}/{path}") from error


class GitHubSource:
    def __init__(self, url, local_root=None, fetch=None, tree_reader=None):
        if not isinstance(url, str) or len(url) > 1536 or any(char.isspace() for char in url):
            raise ValueError("An extension registry entry must be a pinned GitHub folder URL.")
        parsed = urlsplit(url)
        parts = parsed.path.removeprefix("/").removesuffix("/").split("/")
        if parsed.scheme != "https" or parsed.netloc != "github.com" or parsed.query or parsed.fragment or len(parts) < 4:
            raise ValueError("An extension registry entry must be a pinned GitHub folder URL.")
        owner, repository, kind, commit, *path_parts = parts
        if not OWNER.fullmatch(owner) or not REPOSITORY.fullmatch(repository) or repository in {".", ".."} or repository.endswith(".git") or kind != "tree" or not COMMIT.fullmatch(commit):
            raise ValueError("An extension registry entry must use a full GitHub commit and optional folder.")
        self.path = unquote("/".join(path_parts), errors="strict")
        if path_parts and validate_path(self.path) != [unquote(part, errors="strict") for part in path_parts]:
            raise ValueError("An extension registry folder has an encoded separator.")
        self.owner, self.repository, self.commit = owner, repository, commit
        self.name = self.path.split("/")[-1] if self.path else self.repository
        self.url = f"https://github.com/{owner}/{repository}/tree/{commit}"
        if self.path:
            self.url += "/" + quote(self.path)
        self._fetch = fetch or fetch_raw
        self._tree_reader = tree_reader or read_git_tree
        self._local = None
        if (local_root is not None and (owner.lower(), repository.lower()) == LOCAL_REPOSITORY
                and self.path.startswith("Extensions/")):
            local = Path(local_root)
            for part in validate_path(self.path):
                local /= part
                if not stat.S_ISDIR(local.lstat().st_mode):
                    raise ValueError("An extension development folder must be an ordinary directory.")
            self._local = local

    @property
    def is_local(self):
        return self._local is not None

    def raw_url(self, relative_path):
        validate_path(relative_path)
        path = f"{self.path}/{relative_path}" if self.path else relative_path
        return f"https://raw.githubusercontent.com/{self.owner}/{self.repository}/{self.commit}/{quote(path)}"

    @cached_property
    def _entries(self):
        raw = self._tree_reader(self.owner, self.repository, self.commit, self.path)
        result = {}
        for row in raw.split(b"\0")[:-1]:
            entry, path = row.split(b"\t", 1)
            mode, object_type, oid = entry.decode("ascii").split(" ")
            path = path.decode("utf-8")
            if path in result:
                raise ValueError("A GitHub extension tree contains duplicate paths.")
            result[path] = (mode, object_type, oid)
        return result

    def read(self, relative_path, maximum, optional=False):
        parts = validate_path(relative_path)
        if self.is_local:
            candidate = self._local
            try:
                for part in parts[:-1]:
                    candidate /= part
                    if not stat.S_ISDIR(candidate.lstat().st_mode):
                        raise ValueError("A development file parent is not an ordinary directory.")
                return read_regular_file(candidate / parts[-1], maximum)
            except FileNotFoundError:
                if optional:
                    return None
                raise
        item = self._entries.get(relative_path)
        if item is None:
            if optional:
                return None
            raise ValueError("Missing extension file: " + relative_path)
        mode, object_type, oid = item
        if object_type != "blob" or mode not in {"100644", "100755"} or not COMMIT.fullmatch(oid):
            raise ValueError("Expected a regular Git blob: " + relative_path)
        data = self._fetch(self.raw_url(relative_path), maximum)
        header = f"blob {len(data)}\0".encode("ascii")
        if len(data) > maximum or hashlib.sha1(header + data, usedforsecurity=False).hexdigest() != oid:
            raise ValueError("GitHub file failed its size or Git blob check: " + relative_path)
        return data

    def files(self):
        if self.is_local:
            paths = {}
            for directory, folders, filenames in os.walk(self._local):
                for name in folders + filenames:
                    path = Path(directory, name)
                    relative = path.relative_to(self._local).as_posix()
                    if not include_runtime(relative):
                        if name in folders:
                            folders.remove(name)
                        continue
                    mode = path.lstat().st_mode
                    if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                        raise ValueError("Unsupported development file type: " + relative)
                    paths[relative] = stat.S_ISDIR(mode)
        else:
            paths = {path: kind == "tree" and mode == "040000"
                     for path, (mode, kind, _) in self._entries.items() if include_runtime(path)}
        for path in paths:
            validate_path(path)
        if len({p.casefold() for p in paths}) != len(paths):
            raise ValueError("GitHub extension paths conflict on case-insensitive volumes.")
        selected = sorted(p for p, directory in paths.items() if not directory)
        if not selected or len(selected) > MAX_FILES or sum(paths.values()) > MAX_FILES:
            raise ValueError("GitHub extension file inventory exceeds its package limits.")
        result = {}
        remaining = MAX_PACKAGE_BYTES
        for path in selected:
            data = self.read(path, min(MAX_FILE_BYTES, remaining))
            remaining -= len(data)
            result[path] = data
        return result


def read_registry(path, *, local_root=None, fetch=None, tree_reader=None):
    value = json.loads(read_regular_file(Path(path), MAX_REGISTRY))
    if (not isinstance(value, dict) or set(value) != {"schemaVersion", "extensions"}
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or not isinstance(value["extensions"], list) or len(value["extensions"]) > 256):
        raise ValueError("Invalid GitHub extension registry schema.")
    sources = [GitHubSource(url, local_root, fetch, tree_reader) for url in value["extensions"]]
    keys = {(source.owner.lower(), source.repository.lower(), source.path) for source in sources}
    if len(keys) != len(sources):
        raise ValueError("The GitHub registry contains a duplicate extension folder.")
    return sources
