# gpuworks_website

GPUWorks 的独立发布网站，线上地址为 <https://gpuworks.zstack.ai>。

## 目录

- `public/`：静态页面、样式、脚本与真实产品截图。
- `deploy/`：Caddy 配置、GitLab 数据/制品刷新脚本和 systemd timer。

CI 状态由 mirror1 每 5 分钟从 `wei.wang/gpuworks` 的 GitLab API 刷新。下载区只同步最新成功的 master `release-build` 制品；失败或运行中的 pipeline 不会覆盖当前发布包。

真机通过率口径为 `success / (success + failed)`。`skipped`、`manual`、`canceled`、`running`、`pending` 与 `waiting_for_resource` 不进入分母，页面同时展示有效样本数、未执行数、最近成功时间和该次成功耗时。

部署说明见 [`deploy/README.md`](deploy/README.md)。GitLab token 只存在于 mirror1 的 `config/gitlab.env`，不进入仓库或公开目录。
