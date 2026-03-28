# architec-release

`architec-release` 是 Architec 的发布控制仓，不是对外给用户下载的正式发布页。

它负责：

- release 构建与打包
- 安装脚本维护
- GitHub Releases 发布自动化
- 安装回归验证

对外公开给用户访问和下载的仓库是：

- `bfly123/architec-releases`
- <https://github.com/bfly123/architec-releases>

官网入口是：

- <https://www.architec.top>
- <https://www.architec.top/how-it-works>

## 仓库角色

这套发布体系目前分成三层：

- 开发源码仓：`../architec`
- 网站与授权仓：`../architec-cloud`
- 发布控制仓：`../architec-release`

默认本地布局：

```text
/home/bfly/workspace/
  architec/
  architec-cloud/
  architec-release/
```

## 关键目录

- 发布脚本：`tools/`
- 发布文档：`docs/`
- 本地生成产物：`release-assets/`

## 日常使用

构建 release 资产：

```bash
python3 tools/build_release.py --with-nuitka
```

执行真实安装回归：

```bash
bash tools/release_install_smoke.sh
```

从开发仓切正式版本：

```bash
bash tools/cut_release.sh
```

## 对外说明应该看哪里

如果你要维护 GitHub 上给用户看的下载、安装和使用说明，优先维护：

- 公开 release 仓 README：`bfly123/architec-releases`
- GitHub release 正文说明
- 官网功能介绍页：<https://www.architec.top/how-it-works>

这个仓库更偏内部发布运维，不应该承载面向普通用户的主要产品介绍。

## 可覆盖环境变量

当三个仓库不是兄弟目录时，可以覆盖：

- `ARCHITEC_SOURCE_DIR`
- `ARCHITEC_CLOUD_DIR`
- `ARCHITEC_HIPPOCAMPUS_SOURCE`
- `ARCHITEC_LLMGATEWAY_SOURCE`
