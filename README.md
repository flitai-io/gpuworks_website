# gpuworks_website

GPUWorks 文档站的主题与网站资源。文档本身在 <https://gpuworks.readthedocs.io/>（默认显示最新正式版 `stable`，
另有跟随 master 的 `latest` 与各版本），由 Read the Docs 从
[flitai-io/gpuworks](https://github.com/flitai-io/gpuworks) 的 `docs/`、`docs-en/` 构建。

## 目录

- `oink/`：文档站的 Hugo 主题。
- `public/`：网站的静态页面、样式、脚本与产品截图。
- `deploy/`：网站的部署配置与刷新脚本。

## oink 主题

`oink/` 源自 <https://github.com/pgsty/oink>（v1.0.0）。GPUWorks 仓库的 `docs-site/build.sh` 在构建时克隆本仓库，
以 `oink/` 作为 Hugo 主题目录（`theme: oink`），GPUWorks 仓库本身不再 vendor 主题文件；Read the Docs 通过项目环境变量
`WEBSITE_REPO` 指定本仓库的克隆地址。

更新主题：从上游 release 拷贝新版覆盖 `oink/` 后提交，文档站的下一次构建即生效。
