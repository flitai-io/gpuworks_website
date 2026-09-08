# GPUWorks release website

Static release website for `https://gpuworks.zstack.ai`.

- `public/`: HTML, CSS, JavaScript, product screenshots, release files and generated JSON.
- `deploy/refresh-data.sh`: reads the last 20 master pipelines and their jobs from GitLab, then mirrors and merges the newest pipeline whose `release-build` and `release-build-macos` jobs both succeeded.
- `deploy/Caddyfile`: dedicated Caddy site block.
- `deploy/gpuworks-site-refresh.*`: five-minute systemd refresh timer.

The GitLab token is never stored in the repository or public directory. The deployed service reads it from `/home/zstack/gpuworks-site/config/gitlab.env` with mode `0600`.

`SITE_ROOT` is fixed by the systemd service to `/home/zstack/gpuworks-site/public`; only `GITLAB_URL` and `GITLAB_TOKEN` belong in the private environment file.

Pass-rate semantics are deliberately narrow: `success / (success + failed)`. Running, queued, canceled, skipped and manual jobs are excluded. Fixed gpu3, Ascend and PPU acceptance is not represented as continuous CI because those machines are not registered as dedicated CI jobs.
