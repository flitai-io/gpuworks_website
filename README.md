# gpuworks_website

GPUWorks 的独立发布网站，线上地址为 <https://gpuworks.zstack.ai>。

## 目录

- `public/`：静态页面、样式、脚本与真实产品截图。
- `deploy/`：Caddy 配置、GitLab 数据/制品刷新脚本和 systemd timer。
- `public/docs/`：由 GPUWorks 仓库的 `docs-build` 成功制品生成，本站不手工编辑其中的页面。

CI 状态由 mirror1 每 5 分钟从 `wei.wang/gpuworks` 的 GitLab API 刷新。下载区只同步最新一个
同时成功完成 `release-build`（Linux）和 `release-build-macos` 的 master pipeline，并在发布前
校验、合并两份制品；失败、运行中或只有一半成功的 pipeline 不会覆盖当前发布包。文档区只同步最新成功的 master `docs-build` 制品。

真机 case 从最近 pipeline 的 `cloud-smoke` 与 `cloud-full` stage 动态发现，不在前端维护固定名称列表。通过率口径为 `success / (success + failed)`。`skipped`、`manual`、`canceled`、`running`、`pending` 与 `waiting_for_resource` 不进入分母，页面同时展示有效样本数、明确记录的未执行数、最近成功时间和该次成功耗时。

部署说明见 [`deploy/README.md`](deploy/README.md)。GitLab token 只存在于 mirror1 的 `config/gitlab.env`，不进入仓库或公开目录。

## oink 主题（2026-09-29 新增）

`oink/` 是文档站主题，源镜像自 <https://github.com/pgsty/oink>（v1.0.0），因 CI runner 无
github.com 出网而托管在此。GPUWorks 仓库 `docs-site/build.sh` 在构建时克隆本仓库并使用
`oink/` 作为 hugo theme 目录（`theme: oink`），gpuworks 仓库本身不再 vendor 主题文件。

更新主题：在有公网的机器上从上游 release 拷贝新版覆盖 `oink/` 后提交；docs-build 跟随本仓库
master 构建即生效。
