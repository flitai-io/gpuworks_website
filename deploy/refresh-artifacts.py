#!/usr/bin/env python3
"""Refresh the static GPUWorks artifacts site (gpuworks.zstack.ai/artifacts).

Runs on mirror1 from the gpuworks-site systemd timer (deploy/
gpuworks-site-artifacts.timer). Pipeline:

  1. list artifacts/ on git master via the GitLab tree API and diff against
     the last synced state (blob SHAs); fetch only changed files raw, or the
     whole repo archive on first run / very large diffs;
  2. stage the tree for Hugo: markdown rendered as pages (frontmatter status,
     links rewritten, README.md as section landing, synthesized section pages
     with a generated file table), every other file served verbatim under
     /artifacts/f/ plus a sidebar wrapper page at its natural path;
  3. build with Hugo (binary auto-installed from the local rustfs mirror),
     drop in the wrapper pages and manifest, validate, and atomically swap
     $SITE_ROOT/artifacts (keeping the previous build as artifacts.previous).

Any failure exits non-zero and leaves the currently published site untouched.
Requires only the Python 3 standard library.
"""

import concurrent.futures
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

SITE_ROOT = Path(os.environ.get("SITE_ROOT", "/home/zstack/gpuworks-site/public")).resolve()
SITE_HOME = Path(os.environ.get("GPUWORKS_SITE_HOME", SITE_ROOT.parent)).resolve()
WORK_ROOT = Path(os.environ.get("ARTIFACTS_WORK_ROOT", SITE_HOME / "artifacts-work")).resolve()
SITE_SRC = SITE_HOME / "artifacts-site"  # layouts/hugo.yaml/assets from this repo

GITLAB_URL = os.environ.get("GITLAB_URL", "").rstrip("/")
GITLAB_TOKEN = os.environ.get("GITLAB_TOKEN", "")
PROJECT_PATH = os.environ.get("GITLAB_PROJECT_PATH", "wei.wang/gpuworks")
REF = os.environ.get("GITLAB_REF", "master")
SRC = os.environ.get("ARTIFACTS_SOURCE_DIR", "artifacts")

HUGO_VERSION = os.environ.get("HUGO_VERSION", "0.165.0")
HUGO_MIRROR = os.environ.get("HUGO_MIRROR", "http://127.0.0.1:9000/gpuworks-mirror/hugo").rstrip("/")
HUGO_BIN = os.environ.get("HUGO_BIN", "")

FULL_SYNC_THRESHOLD = int(os.environ.get("ARTIFACTS_FULL_SYNC_THRESHOLD", "150"))
FETCH_WORKERS = int(os.environ.get("ARTIFACTS_FETCH_WORKERS", "8"))

API_BASE = f"{GITLAB_URL}/api/v4/projects/{urllib.parse.quote(PROJECT_PATH, safe='')}"
BLOB_URL_BASE = f"{GITLAB_URL}/{PROJECT_PATH}/-/blob/{REF}"
PAGE_SIZE = 100

MD_EXT = ".md"


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def die(msg):
    log(f"ERROR: {msg}")
    sys.exit(1)


# ---------------------------------------------------------------- GitLab API


def http_get(url, dest=None, attempts=3):
    """GET url with the private token; returns decoded body or streams to dest."""
    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"PRIVATE-TOKEN": GITLAB_TOKEN})
            with urllib.request.urlopen(req, timeout=120) as resp:
                if dest is None:
                    return resp.read()
                tmp = Path(str(dest) + ".part")
                with open(tmp, "wb") as fh:
                    shutil.copyfileobj(resp, fh, 1024 * 256)
                os.replace(tmp, dest)
                return None
        except Exception as exc:  # noqa: BLE001 - retry any transport error
            last = exc
            if attempt + 1 < attempts:
                time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"GET {url} failed after {attempts} attempts: {last}")


def api_json(path):
    return json.loads(http_get(f"{API_BASE}{path}"))


def raw_file_url(rel):
    """rel is relative to artifacts/; the files API wants repo-root paths."""
    repo_path = f"{SRC}/{rel}" if rel else SRC
    return f"{API_BASE}/repository/files/{urllib.parse.quote(repo_path, safe='')}/raw?ref={urllib.parse.quote(REF, safe='')}"


def list_tree():
    """Return (blobs, dirs): blobs = {rel: sha}, dirs = set of dir rels."""
    blobs, dirs = {}, set()
    page = 1
    while True:
        entries = api_json(
            f"/repository/tree?path={urllib.parse.quote(SRC, safe='')}"
            f"&recursive=true&per_page={PAGE_SIZE}&page={page}"
        )
        for entry in entries:
            rel = entry["path"][len(SRC) + 1:]
            if entry["type"] == "tree":
                dirs.add(rel)
                continue
            if entry.get("mode") not in ("100644", "100755"):
                log(f"skip non-regular file {entry['path']} (mode {entry.get('mode')})")
                continue
            blobs[rel] = entry["id"]
        if len(entries) < PAGE_SIZE:
            break
        page += 1
    return blobs, dirs


def git_blob_sha(data):
    return hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()


def head_commit():
    c = api_json(f"/repository/commits/{urllib.parse.quote(REF, safe='')}")
    return {"sha": c["id"], "short": c["short_id"], "created_at": c.get("created_at", "")}


def fetch_raw(rel, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    http_get(raw_file_url(rel), dest=dest)


def fetch_ignore(blobs):
    if ".ignore" not in blobs:
        return set()
    data = http_get(raw_file_url(".ignore"))
    excluded = {".ignore"}
    for line in data.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        excluded.add(line)
    return excluded


# ------------------------------------------------------------------- syncing


def count_changes(state_blobs, blobs, tree_dir, excluded):
    changed = 0
    for rel, sha in blobs.items():
        if rel in excluded:
            continue
        if state_blobs.get(rel) != sha or not (tree_dir / rel).is_file():
            changed += 1
    for rel in state_blobs:
        if rel not in blobs and rel not in excluded:
            changed += 1
    return changed


def sync_incremental(state_blobs, blobs, tree_dir, excluded):
    """Fetch changed files, delete removed ones. Returns True if tree changed."""
    todo = [
        rel
        for rel, sha in blobs.items()
        if rel not in excluded and (state_blobs.get(rel) != sha or not (tree_dir / rel).is_file())
    ]
    removed = [rel for rel in state_blobs if rel not in blobs and rel not in excluded]
    if not todo and not removed:
        return False

    log(f"syncing {len(todo)} changed / {len(removed)} removed file(s) incrementally")
    with concurrent.futures.ThreadPoolExecutor(max_workers=FETCH_WORKERS) as pool:
        futures = {pool.submit(fetch_raw, rel, tree_dir / rel): rel for rel in todo}
        for future in concurrent.futures.as_completed(futures):
            future.result()

    for rel in removed:
        target = tree_dir / rel
        if target.is_file():
            target.unlink()
    prune_empty_dirs(tree_dir)
    return True


def prune_empty_dirs(root):
    for path in sorted(
        (p for p in root.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True
    ):
        try:
            path.rmdir()  # only removes empty directories
        except OSError:
            pass


def sync_full_archive(tree_dir, blobs_all, excluded):
    """Rebuild tree_dir from the repo archive; returns {rel: blob sha}."""
    log(f"full sync via repository archive for ref {REF}")
    work = Path(tempfile.mkdtemp(prefix="gpuworks-artifacts-archive."))
    try:
        archive = work / "archive.tar.gz"
        http_get(f"{API_BASE}/repository/archive.tar.gz?sha={urllib.parse.quote(REF, safe='')}", dest=archive)
        if tree_dir.exists():
            shutil.rmtree(tree_dir)
        tree_dir.mkdir(parents=True)
        shas = {}
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar:
                parts = member.name.split("/", 1)
                if len(parts) != 2 or not parts[1]:
                    continue  # top-level directory entry or global header
                rel = parts[1]
                if not (rel == SRC or rel.startswith(SRC + "/")):
                    continue
                if member.isdir():
                    continue
                if not member.isfile():
                    log(f"skip non-regular archive member {member.name}")
                    continue
                rel = rel[len(SRC) + 1:]
                if rel in excluded:
                    continue
                data = tar.extractfile(member).read()
                dest = tree_dir / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
                shas[rel] = git_blob_sha(data)
        missing = set(blobs_all) - set(shas) - excluded
        if missing:
            log(f"archive missing {len(missing)} tree entries; fetching them raw")
            with concurrent.futures.ThreadPoolExecutor(max_workers=FETCH_WORKERS) as pool:
                futures = {pool.submit(fetch_raw, rel, tree_dir / rel): rel for rel in missing}
                for future in concurrent.futures.as_completed(futures):
                    future.result()
        return shas
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ------------------------------------------------------------------ staging


class Stager:
    def __init__(self, tree_dir, excluded, blobs, dirs):
        self.tree_dir = tree_dir
        self.excluded = excluded
        self.blobs = blobs  # rel -> sha (all entries, excluded included)
        self.dirs = dirs
        self.md = set()
        self.files = set()
        self.dirs_used = set()
        for rel in blobs:
            if rel in excluded:
                continue
            if rel.lower().endswith(MD_EXT):
                self.md.add(rel)
            else:
                self.files.add(rel)
            parent = posixpath.dirname(rel)
            while parent:
                self.dirs_used.add(parent)
                parent = posixpath.dirname(parent)
        self.titles = {}

    # -- url mapping --

    def site_url_for(self, rel):
        if not rel:
            return "/artifacts/"
        if rel in self.excluded:
            return f"{BLOB_URL_BASE}/{SRC}/{rel}"
        if rel in self.dirs_used:
            return f"/artifacts/{rel}/"
        if rel in self.md:
            parent, base = posixpath.split(rel)
            if base == "README.md":
                return "/artifacts/" + (parent + "/" if parent else "")
            return f"/artifacts/{rel[:-len(MD_EXT)]}/"
        if rel in self.files:
            if posixpath.basename(rel) == "index.html":
                # would collide with the directory's section page (dir/index.html)
                return f"/artifacts/f/{rel}"
            return f"/artifacts/{rel}"
        return f"{BLOB_URL_BASE}/{SRC}/{rel}"

    def blob_url(self, repo_path):
        return f"{BLOB_URL_BASE}/{repo_path}"

    def map_url(self, target, from_rel):
        """Rewrite a link found in markdown. Returns None to keep it as-is."""
        t = target.strip()
        if not t or t.startswith("#"):
            return None
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.\-]*:", t) or t.startswith("//"):
            return None
        frag = ""
        if "#" in t:
            t, _, frag = t.partition("#")
            frag = "#" + frag
        if not t:
            return None
        path = urllib.parse.unquote(t)
        if path.startswith("/"):
            repo_path = path.lstrip("/")
        else:
            # from_rel is artifacts-relative; resolve against its repo-root dir
            base_dir = posixpath.join(SRC, posixpath.dirname(from_rel))
            repo_path = posixpath.normpath(posixpath.join(base_dir, path))
            if repo_path in (".", "..") or repo_path.startswith("../"):
                return None
        if repo_path == SRC or repo_path.startswith(SRC + "/"):
            rel = "" if repo_path == SRC else repo_path[len(SRC) + 1:]
            return self.site_url_for(rel) + frag
        if repo_path.startswith("docs/"):
            p = repo_path[len("docs/"):]
            if p.endswith(".md"):
                p = p[:-3]
            if p in ("", "README.md", "README"):
                return "/docs/" + frag
            if not p.endswith("/"):
                p += "/"
            return "/docs/" + p + frag
        return self.blob_url(repo_path) + frag

    # -- link rewriting --

    MD_LINK = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
    MD_REFDEF = re.compile(r"^(\s*\[[^\]]+\]:\s*)(\S+)(\s*)$", re.M)
    HTML_ATTR = re.compile(r'((?:href|src)\s*=\s*")([^"]+)(")')

    def rewrite_md(self, text, rel):
        def sub_md(m):
            new = self.map_url(m.group(2), rel)
            return m.group(1) + (new if new is not None else m.group(2)) + m.group(3)

        def sub_refdef(m):
            new = self.map_url(m.group(2), rel)
            return m.group(1) + (new if new is not None else m.group(2)) + m.group(3)

        text = self.MD_LINK.sub(sub_md, text)
        text = self.MD_REFDEF.sub(sub_refdef, text)
        return text

    def rewrite_html(self, text, rel):
        """Only rewrite links pointing at rendered markdown; relative asset
        links between raw files keep working under /f/ and must stay alone."""

        def sub(m):
            new = self.map_url(m.group(2), rel)
            if new is not None and new.startswith("/artifacts/") and new != m.group(2):
                return m.group(1) + new + m.group(3)
            return m.group(0)

        return self.HTML_ATTR.sub(sub, text)

    # -- markdown massaging --

    @staticmethod
    def _quote_yaml(value):
        return json.dumps(value, ensure_ascii=False)

    def ensure_title(self, text, rel):
        if rel in self.titles:
            return text, self.titles[rel]
        stem = posixpath.splitext(posixpath.basename(rel))[0]
        fm_end = -1
        if text.startswith("---\n"):
            fm_end = text.find("\n---", 3)

        def find_title(body):
            m = re.search(r"^#\s+(.+?)\s*$", body, re.M)
            title = m.group(1).strip() if m else stem
            return title.strip("*`").strip()

        if fm_end != -1:
            block = text[4:fm_end]
            body = text[fm_end + 4:]
            m = re.search(r'^title:\s*(.+?)\s*$', block, re.M)
            if m:
                raw = m.group(1).strip()
                if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
                    raw = raw[1:-1]
                self.titles[rel] = raw
                return text, raw
            title = find_title(body)
            self.titles[rel] = title
            return text[:4] + f"title: {self._quote_yaml(title)}\n" + text[4:], title

        title = find_title(text)
        self.titles[rel] = title
        header = f"---\ntitle: {self._quote_yaml(title)}\n---\n\n"
        return header + text, title

    def files_table(self, dir_rel):
        prefix = dir_rel + "/" if dir_rel else ""
        rows = []
        for rel in sorted(self.files):
            if posixpath.dirname(rel) != dir_rel:
                continue
            size = (self.tree_dir / rel).stat().st_size
            rows.append(f"| [{posixpath.basename(rel)}](/artifacts/{rel}) | {human_size(size)} |")
        if not rows:
            return ""
        return "\n## 目录内文件\n\n| 文件 | 大小 |\n|---|---|\n" + "\n".join(rows) + "\n"

    # -- staging into the hugo project --

    def stage(self, site):
        content = site / "content"
        static_f = site / "static" / "f"
        content.mkdir(parents=True)
        static_f.mkdir(parents=True)

        for rel in sorted(self.md):
            text = (self.tree_dir / rel).read_text(encoding="utf-8", errors="replace")
            text = self.rewrite_md(text, rel)
            text, _ = self.ensure_title(text, rel)
            parent, base = posixpath.split(rel)
            dest = content / parent / ("_index.md" if base == "README.md" else base)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(text, encoding="utf-8")

        for rel in sorted(self.files):
            dest = static_f / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.tree_dir / rel, dest)

        # section pages: README.md became _index.md above; synthesize the rest
        synthesized = 0
        for dir_rel in sorted(self.dirs_used):
            index = content / dir_rel / "_index.md"
            if index.is_file():
                text = index.read_text(encoding="utf-8")
                table = self.files_table(dir_rel)
                if table:
                    index.write_text(text.rstrip() + "\n" + table, encoding="utf-8")
                continue
            title = posixpath.basename(dir_rel)
            body = (
                "---\n"
                f"title: {self._quote_yaml(title)}\n"
                "generated: true\n"
                "---\n\n"
                f"目录 `{SRC}/{dir_rel}/`。\n" + self.files_table(dir_rel)
            )
            index.parent.mkdir(parents=True, exist_ok=True)
            index.write_text(body, encoding="utf-8")
            synthesized += 1
        if synthesized:
            log(f"synthesized {synthesized} section page(s) for directories without README")

        (site / "static" / "_assets").mkdir(parents=True, exist_ok=True)
        tree_json = self.build_tree_json()
        (site / "static" / "_assets" / "tree.json").write_text(
            json.dumps(tree_json, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
        )

    def build_tree_json(self):
        root = {"n": "artifacts", "t": "d", "h": "/artifacts/", "ch": []}
        index = {"": root}

        def node_for(rel, is_dir):
            if is_dir:
                return {"n": posixpath.basename(rel), "t": "d", "h": f"/artifacts/{rel}/", "ch": []}
            entry = {"n": posixpath.basename(rel), "t": "f", "h": self.site_url_for(rel)}
            title = self.titles.get(rel)
            if title:
                entry["title"] = title
            return entry

        for rel in sorted(self.dirs_used, key=lambda p: (p.count("/"), p)):
            node = node_for(rel, True)
            index[rel] = node
            index[posixpath.dirname(rel)]["ch"].append(node)
        for rel in sorted(self.md | self.files):
            index[posixpath.dirname(rel)]["ch"].append(node_for(rel, False))

        def sort_children(node):
            node["ch"].sort(key=lambda c: (0 if c["t"] == "d" else 1, c["n"]))
            for child in node["ch"]:
                if child["t"] == "d":
                    sort_children(child)

        sort_children(root)
        return root


def human_size(num):
    for unit in ("B", "KB", "MB", "GB"):
        if num < 1024 or unit == "GB":
            return f"{num:.0f}{unit}" if unit == "B" else f"{num:.1f}{unit}"
        num /= 1024.0


# -------------------------------------------------------------------- build


def code_fingerprint():
    """Fingerprint of everything that affects the built output besides content."""
    h = hashlib.sha256()
    inputs = [Path(__file__)]
    if SITE_SRC.is_dir():
        inputs.extend(sorted(p for p in SITE_SRC.rglob("*") if p.is_file()))
    for path in inputs:
        h.update(str(path).encode())
        h.update(b"\0")
        h.update(hashlib.sha256(path.read_bytes()).digest())
        h.update(b"\0")
    return h.hexdigest()[:16]


def ensure_hugo():
    if HUGO_BIN:
        return HUGO_BIN
    bin_dir = SITE_HOME / "bin"
    hugo = bin_dir / "hugo"
    if hugo.is_file() and os.access(hugo, os.X_OK):
        return str(hugo)
    name = f"hugo_extended_{HUGO_VERSION}_linux-amd64.tar.gz"
    bin_dir.mkdir(parents=True, exist_ok=True)
    log(f"installing hugo {HUGO_VERSION} from {HUGO_MIRROR}")
    work = Path(tempfile.mkdtemp(prefix="gpuworks-hugo."))
    try:
        archive = work / name
        http_get(f"{HUGO_MIRROR}/{name}", dest=archive)
        expected = http_get(f"{HUGO_MIRROR}/{name}.sha256").decode().split()[0].strip().lower()
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != expected:
            die(f"hugo tarball sha256 mismatch: expected {expected}, got {actual}")
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar.getmembers():
                if Path(member.name).name == "hugo" and member.isfile():
                    member.name = "hugo"
                    tar.extract(member, work)
                    break
            else:
                die("hugo binary not found in tarball")
        target = bin_dir / f"hugo-{HUGO_VERSION}"
        shutil.copyfile(work / "hugo", target)
        target.chmod(0o755)
        os.replace(target, hugo)
        return str(hugo)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def write_manifest(site, commit, hugo_version, synced_at):
    manifest = {
        "project": "gpuworks",
        "ref": REF,
        "commit": commit["sha"],
        "short_commit": commit["short"],
        "synced_at": synced_at,
        "generated_at": synced_at,
        "generator": "gpuworks_website artifacts-site",
        "hugo_version": hugo_version,
    }
    data_dir = site / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    (data_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return manifest


WRAPPER_TEMPLATE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{title} · GPUWorks Artifacts</title>
<link rel="stylesheet" href="/artifacts/_assets/site.css">
<script src="/artifacts/_assets/tree.js" defer></script>
</head>
<body class="shell-body wrap-body">
<aside class="sidebar" id="sidebar">
  <div class="sidebar-head">
    <a class="brand" href="/artifacts/">GPU<b>Works</b> artifacts</a>
    <button class="sidebar-close" id="sidebar-close" aria-label="关闭目录">✕</button>
  </div>
  <nav class="tree" id="tree" aria-label="文件目录"></nav>
</aside>
<div class="sidebar-backdrop" id="sidebar-backdrop"></div>
<div class="frame">
  <header class="topbar">
    <div class="topbar-inner">
      <button class="menu-btn" id="menu-btn" aria-label="打开目录">☰</button>
      <nav class="topnav">
        <a href="/">GPUWorks</a>
        <a href="/docs/">文档</a>
        <a href="{raw_url}" target="_blank" rel="noopener">原文</a>
        <a href="{repo_url}" rel="noopener">GitLab</a>
      </nav>
    </div>
  </header>
  <main class="wrap-main">
    <div class="wrap-file-bar">
      <span class="file-name">{rel}</span>
      <span>{size}</span>
      <a href="{raw_url}" target="_blank" rel="noopener">新窗口打开原文</a>
    </div>
    <iframe class="fileframe" src="{raw_url}" title="{title_attr}"></iframe>
  </main>
</div>
</body>
</html>
"""


def generate_wrappers(public, stager):
    count = 0
    skipped = 0
    for rel in sorted(stager.files):
        if stager.site_url_for(rel) != f"/artifacts/{rel}":
            continue  # this file is served raw instead of through a wrapper
        dest = public / rel
        if dest.exists():
            log(f"wrapper path collision for {rel}, keeping existing output")
            skipped += 1
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        size = human_size((stager.tree_dir / rel).stat().st_size)
        dest.write_text(
            WRAPPER_TEMPLATE.format(
                title=rel,
                title_attr=posixpath.basename(rel).replace('"', "&quot;"),
                rel=rel,
                size=size,
                raw_url=f"/artifacts/f/{rel}",
                repo_url=f"{BLOB_URL_BASE}/{SRC}/{rel}",
            ),
            encoding="utf-8",
        )
        count += 1
    log(f"generated {count} wrapper page(s)" + (f", skipped {skipped}" if skipped else ""))


def build_and_publish(tree_dir, excluded, blobs, dirs, commit):
    site = WORK_ROOT / "site"
    if site.exists():
        shutil.rmtree(site)
    site.mkdir(parents=True)
    shutil.copytree(SITE_SRC / "layouts", site / "layouts")
    shutil.copyfile(SITE_SRC / "hugo.yaml", site / "hugo.yaml")

    synced_at = time.strftime("%Y-%m-%dT%H:%M:%SZ")
    stager = Stager(tree_dir, excluded, blobs, dirs)
    stager.stage(site)

    assets_src = SITE_SRC / "assets"
    assets_dst = site / "static" / "_assets"
    assets_dst.mkdir(parents=True, exist_ok=True)
    for asset in sorted(assets_src.iterdir()):
        if asset.is_file():
            shutil.copyfile(asset, assets_dst / asset.name)

    hugo = ensure_hugo()
    version_out = subprocess.run(
        [hugo, "version"], capture_output=True, text=True, check=True
    ).stdout.strip()
    hugo_version = version_out.split()[1] if len(version_out.split()) > 1 else version_out
    write_manifest(site, commit, hugo_version, synced_at)

    hugo_env = dict(os.environ, HUGO_CACHEDIR=str(WORK_ROOT / "hugo-cache"))
    subprocess.run(
        [
            hugo,
            "--source",
            str(site),
            "--destination",
            str(site / "public"),
            "--gc",
            "--minify",
            "--environment",
            "production",
            "--logLevel",
            "info",
        ],
        check=True,
        env=hugo_env,
    )

    generate_wrappers(site / "public", stager)
    shutil.copyfile(site / "data" / "manifest.json", site / "public" / "artifacts-manifest.json")

    # validation before anything touches the live site
    public = site / "public"
    landing = public / "index.html"
    if not landing.is_file() or landing.stat().st_size == 0:
        die("built site has no landing page")
    if not (public / "f").is_dir():
        die("built site is missing the raw file tree under f/")
    if not (public / "_assets" / "tree.json").is_file():
        die("built site is missing tree.json")
    if not (public / "artifacts-manifest.json").is_file():
        die("built site is missing the manifest")
    docs_pages = len(list(public.rglob("index.html")))
    if docs_pages < 10:
        die(f"suspiciously few generated pages ({docs_pages})")

    stage = SITE_ROOT / "artifacts.next"
    current = SITE_ROOT / "artifacts"
    previous_keep = SITE_ROOT / "artifacts.previous"
    previous_tmp = WORK_ROOT / "artifacts.previous"
    for path in (stage, previous_tmp):
        if path.exists():
            shutil.rmtree(path)
    shutil.move(str(public), str(stage))
    had_current = current.exists()
    if had_current:
        shutil.move(str(current), str(previous_tmp))
    try:
        shutil.move(str(stage), str(current))
    except Exception:
        if had_current and not current.exists():
            shutil.move(str(previous_tmp), str(current))
        raise
    if previous_tmp.exists():
        if previous_keep.exists():
            shutil.rmtree(previous_keep)
        shutil.move(str(previous_tmp), str(previous_keep))
    log(f"published artifacts site ({docs_pages} pages) from {commit['short']}")

    return synced_at


# --------------------------------------------------------------------- main


def load_state():
    path = WORK_ROOT / "state.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state):
    path = WORK_ROOT / "state.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def published_commit():
    try:
        return json.loads((SITE_ROOT / "artifacts" / "artifacts-manifest.json").read_text())["commit"]
    except Exception:
        return None


def main():
    if not GITLAB_URL or not GITLAB_TOKEN:
        die("GITLAB_URL and GITLAB_TOKEN are required")
    if not SITE_SRC.is_dir():
        die(f"site source not found: {SITE_SRC} (deploy checkout of gpuworks_website?)")

    tree_dir = WORK_ROOT / "tree"
    tree_dir.mkdir(parents=True, exist_ok=True)

    log(f"listing {SRC}/ on {PROJECT_PATH}@{REF}")
    blobs, dirs = list_tree()
    log(f"tree: {len(blobs)} file(s), {len(dirs)} dir(s)")
    excluded = fetch_ignore(blobs)
    excluded &= set(blobs) | {".ignore"}
    commit = head_commit()
    state = load_state()

    fingerprint = code_fingerprint()
    ignore_fp = hashlib.sha256(b"\n".join(sorted(e.encode() for e in excluded))).hexdigest()[:16]
    changed_count = count_changes(state.get("blobs", {}), blobs, tree_dir, excluded)
    needs_full = (
        not state
        or state.get("blobs") is None
        or changed_count > FULL_SYNC_THRESHOLD
        or state.get("ignore_fingerprint") != ignore_fp
    )

    if needs_full:
        synced_shas = sync_full_archive(tree_dir, blobs, excluded)
        changed = True
        state_blobs = synced_shas
    else:
        changed = sync_incremental(state.get("blobs", {}), blobs, tree_dir, excluded)
        state_blobs = blobs

    content_changed = changed or changed_count > 0 or state.get("commit") != commit["sha"]
    code_changed = state.get("code_fingerprint") != fingerprint
    if not content_changed and not code_changed and published_commit() == commit["sha"]:
        log(f"no changes since {commit['short']}; nothing to do")
        return

    if code_changed:
        log("site code changed; rebuilding")
    build_and_publish(tree_dir, excluded, blobs, dirs, commit)

    save_state(
        {
            "commit": commit["sha"],
            "short_commit": commit["short"],
            "synced_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "blobs": state_blobs,
            "ignore_fingerprint": ignore_fp,
            "code_fingerprint": fingerprint,
        }
    )
    log("state saved; done")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        import traceback

        traceback.print_exc()
        sys.exit(1)
