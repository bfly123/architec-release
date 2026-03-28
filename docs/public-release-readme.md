# Architec Releases

Architec 是一个面向复杂工程的架构分析工具。它基于规则和语义对代码库进行全面分析，建立结构索引，识别架构热点，并为新需求与未来演化提供可执行的架构建议。

这个仓库只负责一件事：对外提供 Architec 的正式安装包、安装脚本和版本发布记录。

- 官网：<https://www.architec.top>
- 功能介绍：<https://www.architec.top/how-it-works>
- 最新发布页：<https://github.com/bfly123/architec-releases/releases/latest>

## 下载与安装

推荐直接使用正式安装脚本：

```bash
curl -fsSL https://www.architec.top/downloads/latest/install_prod.sh -o install_prod.sh && bash install_prod.sh
```

安装器会自动完成这些事情：

- 检查基础运行环境
- 下载并安装 `archi`
- 自动安装开源依赖 `hippocampus` 与 `llmgateway`
- 生成默认配置模板
- 把可执行命令放到本机可用路径中

如果你只想手动下载版本资产，可以直接打开：

- <https://github.com/bfly123/architec-releases/releases/latest>

## 安装后怎么用

1. 执行登录授权：

```bash
archi login
```

首次使用时，可以按安装器记录的默认方式完成授权。当前支持：

- 浏览器授权
- 激活码授权

2. 在项目根目录先建立结构上下文：

```bash
hippo .
archi .
```

3. 然后在 Codex / Claude 中继续使用 Archi 结果进行架构分析、优化和后续编程。

## Archi 主要能做什么

- 对整个代码库做全面架构分析，输出架构热点、边界风险和优化方向
- 围绕新功能需求提供架构建议，而不是只做静态评分
- 通过 skill 融入 Codex / Claude，把结构视图和热点问题继续交给 AI 使用
- 持续为后续重构、模块拆分、边界收敛和未来演化提供参考

## 结果会输出到哪里

运行 `hippo .` 和 `archi .` 后，通常会看到两个关键目录：

- `.hippocampus/`
  保存项目结构索引、签名抽取、依赖关系与基础中间结果
- `.architec/`
  保存架构分析结果、热点判断、可视化与报告输出

这两个目录都可以直接给使用者和 AI 助手继续参考。

## 常用命令

```bash
archi --version
archi --help
archi login
archi update
hippo .
archi .
```

## 关于这个仓库

这个仓库不是源码开发仓，而是正式发布仓。

- 这里放的是安装包、安装脚本、校验文件和 release 记录
- 注册、登录、授权、账号状态、设备管理由官网负责
- 本地项目分析仍然在你的机器上进行，不在网站执行

如果你想先了解产品定位和完整使用路径，优先看：

- <https://www.architec.top>
- <https://www.architec.top/how-it-works>
