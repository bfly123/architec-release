<div align="center">
  <img src="https://www.architec.top/logo-mark.svg" alt="Architec Logo" width="88" />
  <h1>Architec</h1>
  <p><strong>我是阿奇(Archi)</strong></p>
  <p>一个基于语义与规则的专业代码架构师</p>
  <p>我专注于构建优美的代码建筑</p>
  <p><strong>I am Archi.</strong></p>
  <p>A semantic, rule-driven professional code architect.</p>
  <p>I focus on building elegant code architecture.</p>
  <p>融入 Codex / Claude，为你的 vibe coding 导航</p>
  <p>Integrated with Codex / Claude to guide your vibe coding.</p>
</div>

<p align="center">
  <a href="https://www.architec.top">Website</a> ·
  <a href="https://www.architec.top/how-it-works">How It Works</a> ·
  <a href="https://github.com/bfly123/architec-releases/releases/latest">Latest Release</a>
</p>

---

## Architec 是什么 / What Architec Is

Architec 基于规则与语义对代码库进行全面分析，建立结构索引，识别架构热点，并为新需求与未来演化提供可执行的架构建议。

Architec uses rules and semantics to analyze codebases in depth, build structural indexes, identify architectural hotspots, and produce actionable guidance for new requirements and long-term evolution.

它不是一个简单的命令行评分器，而是一套面向复杂工程的架构分析入口。它会先结合 Hippo 为项目建立结构索引，再读取规则结果、语义理解、变更上下文与历史热点，把原本分散在代码树里的信息整理成可执行的架构视图。这个视图既能给人看，也能继续交给 Codex / Claude 使用。

It is not a simple CLI scorer. It is an architecture analysis layer for complex engineering systems. It builds on Hippo indexes, rule-based signals, semantic understanding, change context, and historical hotspots to turn scattered repository details into an actionable architecture view for both engineers and AI tools.

## 快速开始 / Quick Start

推荐直接使用正式安装脚本：

Recommended installation command:

```bash
curl -fsSL https://www.architec.top/downloads/latest/install_prod.sh -o install_prod.sh && bash install_prod.sh
```

安装器会自动完成：

The installer automatically:

- 检查基础运行环境
- 下载并安装 `archi`
- 自动安装开源依赖 `hippocampus` 与 `llmgateway`
- 生成默认配置模板
- 把命令放入本机可执行路径
- Checks the local runtime environment
- Downloads and installs `archi`
- Installs the open-source dependencies `hippocampus` and `llmgateway`
- Writes default configuration templates
- Places the executable in a usable local path

安装完成后，推荐按下面顺序开始：

Recommended first-run flow:

```bash
archi login
hippo .
archi .
```

## 它解决什么问题 / What Problem It Solves

大型工程最难的不是写代码，而是在改动前真正理解系统。Architec 的意义，是在你动手之前先给出一张结构化地图：

The hardest part of working in a large system is not writing code. It is understanding the system before you change it. Architec gives you that structured map first:

- 哪些模块最脆弱
- 哪些变更风险最高
- 哪些边界已经开始漂移
- 哪些文件只是局部问题，而不是系统问题
- Which modules are fragile
- Which changes carry the highest risk
- Which boundaries are already drifting
- Which files are only local issues instead of system-level issues

## 核心能力 / Core Capabilities

- 对整个代码库做全面架构分析，输出架构热点、边界风险和优化方向
- 围绕新功能需求提供架构建议，而不是只做静态评分
- 通过 skill 融入 Codex / Claude，把结构视图和热点问题继续交给 AI 使用
- 持续为后续重构、模块拆分、边界收敛和未来演化提供参考
- Full-graph architecture analysis for an entire codebase, including hotspots, boundary risks, and optimization direction
- Architecture advice for new feature goals, not only static scoring
- Skill-based integration into Codex / Claude so the architecture view can continue to guide AI work
- Ongoing support for refactoring, module splits, boundary cleanup, and future evolution

## 怎么使用 / How To Use It

1. 执行登录授权 / Authorize the local install:

```bash
archi login
```

首次使用时，可以按安装器记录的默认方式完成授权。当前支持浏览器授权和激活码授权。

On first use, authorization follows the default mode recorded by the installer. Browser authorization and activation-code authorization are both supported.

2. 在项目根目录建立结构上下文 / Build project context at the project root:

```bash
hippo .
archi .
```

3. 重启 Codex / Claude，让 skill 同步完成，再基于 Archi 结果做优化、评审、拆分与演化决策。

Restart Codex / Claude so the skills refresh, then use Archi outputs for optimization, review, decomposition, and architectural evolution decisions.

## 你会得到什么结果 / What You Get

运行 `hippo .` 和 `archi .` 后，通常会看到两个关键目录：

After running `hippo .` and `archi .`, you will usually see two key directories:

- `.hippocampus/`
  保存项目结构索引、签名抽取、依赖关系与基础中间结果
  Stores project structure indexes, signature extraction, dependency relations, and foundational intermediate artifacts
- `.architec/`
  保存架构分析结果、热点判断、可视化与报告输出
  Stores architecture outputs, hotspot judgments, visual reports, and summary artifacts

这两个目录都可以直接给使用者和 AI 助手继续参考。

Both directories are meant to be directly reusable by engineers and AI assistants.

## 常用命令 / Common Commands

```bash
archi --version
archi --help
archi login
archi update
hippo .
archi .
```

## GitHub 入口说明 / GitHub Entry Role

这里既是 Architec 的 GitHub 发布入口，也是产品说明和版本管理入口。

This repository acts as a GitHub-side release, product overview, and version-management entry for Architec.

- 查看正式安装包和版本记录：GitHub Releases
- 查看完整使用说明：官网 `how-it-works`
- 注册、登录、授权、账号状态和设备管理：官网
- 本地项目分析：在用户自己的机器上执行
- Release packages and version history live in GitHub Releases
- Full usage documentation lives on the website
- Registration, login, authorization, account state, and device management are handled on the website
- Local analysis always runs on the user's own machine

## 相关入口 / Links

- 官网 / Website: <https://www.architec.top>
- 使用说明 / How It Works: <https://www.architec.top/how-it-works>
- 最新发布 / Latest Release: <https://github.com/bfly123/architec-releases/releases/latest>
