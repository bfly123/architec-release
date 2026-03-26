# Architec Release SOP

这份 SOP 只描述你在开发仓里怎样切一个正式版本，不描述功能开发过程。

## 1. 代码和发布物的位置

- 开发源码仓：`bfly123/architec`
- 开发目录：`/home/bfly/workspace/architec`
- 公开发布仓：`bfly123/architec-releases`

原则：

- 只在开发仓里写代码
- 不把安装包提交到开发仓
- 安装包只进入 GitHub Releases

## 2. 日常发布入口

开发仓里已经提供正式发布脚本：

```bash
bash tools/cut_release.sh
```

默认行为：

- 校验 git 工作树是干净的
- 从 `pyproject.toml` 读取版本号
- 生成 tag：`v<version>`
- 运行 `pytest`
- 运行 `architec-cloud` 的 `pnpm build`
- 运行 `architec-cloud` 的 `pnpm smoke`
- 运行真实安装回归：`bash tools/release_install_smoke.sh`
- 创建本地 tag
- push 当前分支和 tag 到 `origin`

正常情况下，push tag 之后由 GitHub Actions 负责把安装包上传到 `bfly123/architec-releases`。

## 3. 推荐发布流程

1. 在开发仓完成功能和修复。
2. 确认版本号已经更新。
3. 执行：

```bash
cd /home/bfly/workspace/architec
bash tools/cut_release.sh
```

4. 去 GitHub 查看源码仓 Actions：
   `Publish Release`
5. 去 GitHub 查看公开发布仓 release 页面：
   `https://github.com/bfly123/architec-releases/releases`
6. 最后再从公开 release 链接做一次真实安装抽查。

## 4. 常用选项

只做本地检查，不 push：

```bash
bash tools/cut_release.sh --no-push
```

当前工作树有未提交修改，但你明确知道自己在做什么：

```bash
bash tools/cut_release.sh --allow-dirty --no-push
```

已经通过 CI 构建验证，但你想从本机直接上传 release 资产：

```bash
bash tools/cut_release.sh --publish-local
```

跳过真实安装回归并不推荐，但可以：

```bash
bash tools/cut_release.sh --skip-release-smoke
```

## 5. 发布前最低要求

至少保证这几项通过：

- `PYTHONPATH=src pytest -q`
- `cd architec-cloud && pnpm build`
- `cd architec-cloud && pnpm smoke`
- `bash tools/release_install_smoke.sh`

其中最后一条最重要，因为它验证的是：

- 网站注册登录
- `/api/cli/authorize`
- 从 GitHub Releases 安装真实 `archi`
- CLI 登录、状态、设备、登出

## 6. 不要做的事

- 不要把 `dist/` 提交到开发仓
- 不要手工把源码同步进 `architec-releases`
- 不要在没跑真实安装回归时就打正式 tag
- 不要把生产密钥放进仓库
