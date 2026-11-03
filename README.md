# gpuworks_website

GPUWorks 的公开文档站在 Read the Docs：<https://gpuworks.readthedocs.io/>（默认显示最新正式版 `stable`，
另有跟随 master 的 `latest` 与各版本 tag）。它由 Read the Docs 从公开仓库
[flitai-io/gpuworks](https://github.com/flitai-io/gpuworks) 的 `docs/`、`docs-en/` 构建，主题取自本仓库的 `oink/`。

本仓库另外承载 GPUWorks 的内网发布站 <https://gpuworks.zstack.ai>（仅公司内网可达）：CI 状态、内网下载与文档镜像。

## 目录

- `public/`：静态页面、样式、脚本与真实产品截图。
- `deploy/`：Caddy 配置、GitLab 数据/制品刷新脚本和 systemd timer。
- `public/docs/`：内网站点的文档镜像，由 GPUWorks 仓库的 `docs-build` 成功制品生成，本站不手工编辑其中的页面；对外请链接 Read the Docs。

CI 状态由 mirror1 每 5 分钟从 `wei.wang/gpuworks` 的 GitLab API 刷新。下载区只同步最新一个
发布 job 全部成功的 master pipeline——四个按包拆分的 `release-build-{linux,macos}-{amd64,arm64}`，
或它们之前的 `release-build`（Linux）与 `release-build-macos`——并在发布前校验、合并各 job 的制品；
失败、运行中或只有部分成功的 pipeline 不会覆盖当前发布包。文档区只同步最新成功的 master `docs-build` 制品。

真机 case 从最近 pipeline 的 `cloud-smoke` 与 `cloud-full` stage 动态发现，不在前端维护固定名称列表。通过率口径为 `success / (success + failed)`。`skipped`、`manual`、`canceled`、`running`、`pending` 与 `waiting_for_resource` 不进入分母，页面同时展示有效样本数、明确记录的未执行数、最近成功时间和该次成功耗时。

部署说明见 [`deploy/README.md`](deploy/README.md)。GitLab token 只存在于 mirror1 的 `config/gitlab.env`，不进入仓库或公开目录。

## oink 主题（2026-09-29 新增）

`oink/` 是文档站主题，源镜像自 <https://github.com/pgsty/oink>（v1.0.0），因 CI runner 无
github.com 出网而托管在此。GPUWorks 仓库 `docs-site/build.sh` 在构建时克隆本仓库并使用
`oink/` 作为 hugo theme 目录（`theme: oink`），gpuworks 仓库本身不再 vendor 主题文件。内网 CI 从 GitLab 克隆；
Read the Docs 通过项目环境变量 `WEBSITE_REPO` 克隆公开镜像 <https://github.com/flitai-io/gpuworks_website>。

更新主题：在有公网的机器上从上游 release 拷贝新版覆盖 `oink/` 后提交；docs-build 与 Read the Docs
跟随本仓库 master 构建即生效（Read the Docs 要等 GitLab 推送镜像同步到 GitHub 后的下一次构建）。
