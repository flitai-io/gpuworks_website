# GPUWorks release website

Static release website for `https://gpuworks.zstack.ai`.

- `public/`: HTML, CSS, JavaScript, product screenshots, release files and generated JSON.
- `deploy/refresh-data.sh`: reads the last 20 master pipelines and their jobs from GitLab, then mirrors and merges the newest pipeline whose release jobs all succeeded: the four per-archive jobs `release-build-{linux,macos}-{amd64,arm64}` (gpuworks MR !410), or `release-build` and `release-build-macos` in pipelines from before them; it also mirrors the newest successful `docs-build` artifact into `public/docs/`.
- `deploy/Caddyfile`: dedicated Caddy site block.
- `deploy/gpuworks-site-refresh.*`: five-minute systemd refresh timer.

## Artifacts browser (`gpuworks.zstack.ai/artifacts`)

`artifacts-site/` plus `deploy/refresh-artifacts.py` publish the gpuworks repository's
`artifacts/` tree (plans, research, acceptance records) as a browsable static site.
Nothing about it lives in the gpuworks repository and it does not depend on its CI:
the refresh script talks to the GitLab API directly.

- `artifacts-site/`: Hugo layouts, config and static assets (sidebar file tree,
  rendered markdown). Assembled into a build directory at refresh time; the synced
  tree is staged as `content/` and `static/f/` (verbatim files).
- `deploy/refresh-artifacts.py`: lists `artifacts/` on master via the GitLab tree
  API, downloads only files whose blob SHA changed (full repo archive on first run
  or very large diffs), rewrites links (in-tree markdown → rendered pages, other
  files → their own path, escaped links → GitLab blob or `/docs/`), builds with
  Hugo (binary auto-installed from the local rustfs mirror bucket
  `gpuworks-mirror/hugo`, currently 0.165.0 like docs CI), generates wrapper pages
  for every non-markdown file (sidebar shell + same-origin iframe showing the raw
  file, which is also directly served under `/artifacts/f/`), and atomically swaps
  `public/artifacts/` keeping the previous build as `public/artifacts.previous/`.
  Files listed in `artifacts/.ignore` (superseded/dropped plan versions) are
  excluded from the site.
- `deploy/gpuworks-site-artifacts.*`: hourly systemd timer, same hardening and
  credentials file as the five-minute refresh; host-side state lives in
  `/home/zstack/gpuworks-site/artifacts-work/` and the hugo binary in
  `/home/zstack/gpuworks-site/bin/` (both gitignored here).

The CSP for `/artifacts/*` is relaxed like `/docs/*` (inline scripts/styles,
Google Fonts) because the synced HTML reports are self-contained and carry their
own inline scripts; `connect-src 'self'` still blocks any outbound request.
`X-Frame-Options` for `/artifacts/*` is `SAMEORIGIN` (the site iframes its own
raw files); every other path keeps `DENY`.

First activation on the host:

```sh
cd /home/zstack/gpuworks-site && git pull --ff-only
sudo install -m 0644 deploy/gpuworks-site-artifacts.service deploy/gpuworks-site-artifacts.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpuworks-site-artifacts.timer
systemctl start gpuworks-site-artifacts.service   # first build (~62 MB archive fetch)
journalctl -u gpuworks-site-artifacts.service -f  # watch it
```

After bumping `HUGO_VERSION` in `refresh-artifacts.py`, mirror that version into
the rustfs bucket once: `ssh mirror1 /opt/gpuworks/hugo-mirror/refresh-hugo-mirror.sh <version>`.


The GitLab token is never stored in the repository or public directory. The deployed service reads it from `/home/zstack/gpuworks-site/config/gitlab.env` with mode `0600`.

`SITE_ROOT` is fixed by the systemd service to `/home/zstack/gpuworks-site/public`; only `GITLAB_URL` and `GITLAB_TOKEN` belong in the private environment file.

Pass-rate semantics are deliberately narrow: `success / (success + failed)`. Running, queued, canceled, skipped and manual jobs are excluded. Fixed gpu3, Ascend and PPU acceptance is not represented as continuous CI because those machines are not registered as dedicated CI jobs.
