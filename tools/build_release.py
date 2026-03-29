#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import gzip
import os
import shutil
import subprocess
import sys
import tarfile
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = Path(os.environ.get("ARCHITEC_SOURCE_DIR", ROOT / "../architec")).resolve()
PYPROJECT = SOURCE_ROOT / "pyproject.toml"
DIST = Path(os.environ.get("ARCHITEC_DIST_DIR", ROOT / "release-assets")).resolve()
DEPENDENCY_WHEEL_SOURCES = {
    "hippocampus": Path(os.environ.get("ARCHITEC_HIPPOCAMPUS_SOURCE", ROOT / "../hippocampus")).resolve(),
    "llmgateway": Path(os.environ.get("ARCHITEC_LLMGATEWAY_SOURCE", ROOT / "../llmgateway")).resolve(),
}


def read_version() -> str:
    payload = tomllib.loads(PYPROJECT.read_text(encoding="utf-8"))
    return str(payload["project"]["version"])


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def release_artifacts() -> list[Path]:
    return sorted(
        path
        for path in DIST.iterdir()
        if path.is_file() and path.name not in {"SHA256SUMS.txt", "RELEASE_NOTES.md"}
    )


def run_build(python_bin: str, clean: bool) -> None:
    if clean:
        shutil.rmtree(DIST, ignore_errors=True)
    DIST.mkdir(parents=True, exist_ok=True)
    subprocess.run([python_bin, "-m", "build", "--outdir", str(DIST), str(SOURCE_ROOT)], check=True)


def run_nuitka_build(python_bin: str) -> None:
    subprocess.run(
        ["bash", str(ROOT / "tools" / "build_nuitka.sh")],
        check=True,
        env={
            **os.environ,
            "PYTHON_BIN": python_bin,
            "ARCHITEC_SOURCE_DIR": str(SOURCE_ROOT),
            "ARCHITEC_DIST_DIR": str(DIST),
        },
    )


def build_dependency_wheels(python_bin: str) -> None:
    for name, source in DEPENDENCY_WHEEL_SOURCES.items():
        pyproject = source / "pyproject.toml"
        if not pyproject.exists():
            raise SystemExit(
                f"Dependency source checkout missing for {name}: {source}. "
                f"Set ARCHITEC_{name.upper()}_SOURCE to a local checkout before building the release."
            )
        subprocess.run(
            [python_bin, "-m", "pip", "wheel", "--no-deps", "--wheel-dir", str(DIST), str(source)],
            check=True,
        )


def build_skills_archive() -> Path:
    archive_path = DIST / "architec-skills.tar.gz"
    skill_dir_names = [
        "codex_skills",
        "claude_skills",
    ]
    skill_dirs = [SOURCE_ROOT / name for name in skill_dir_names]
    missing_dirs = [skill_dir for skill_dir in skill_dirs if not skill_dir.is_dir()]

    if not missing_dirs:
        with tarfile.open(archive_path, "w:gz") as archive:
            for skill_dir in skill_dirs:
                archive.add(skill_dir, arcname=skill_dir.name)
        return archive_path

    temp_tar_path = DIST / "architec-skills.tar"
    try:
        subprocess.run(
            [
                "git",
                "-C",
                str(SOURCE_ROOT),
                "archive",
                "--format=tar",
                "-o",
                str(temp_tar_path),
                "HEAD",
                *skill_dir_names,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        detail = ""
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            detail = f" Git archive error: {exc.stderr.strip()}"
        missing_text = ", ".join(str(path) for path in missing_dirs)
        raise SystemExit(
            f"Missing bundled skill directory in working tree: {missing_text}.{detail}"
        ) from exc

    with temp_tar_path.open("rb") as src, gzip.open(archive_path, "wb") as dst:
        shutil.copyfileobj(src, dst)
    temp_tar_path.unlink(missing_ok=True)
    return archive_path


def write_checksums(version: str) -> Path:
    artifacts = release_artifacts()
    if not artifacts:
        raise SystemExit("No release artifacts found in dist/")

    lines = [f"# Architec {version} release checksums"]
    for artifact in artifacts:
        lines.append(f"{sha256_file(artifact)}  {artifact.name}")

    target = DIST / "SHA256SUMS.txt"
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return target


def write_release_notes(version: str, repo: str) -> Path:
    artifacts = release_artifacts()
    target = DIST / "RELEASE_NOTES.md"
    asset_lines = [f"- `{artifact.name}`" for artifact in artifacts]
    target.write_text(
        "\n".join(
            [
                f"# Architec {version}",
                "",
                "## Architec 是什么",
                "",
                "Architec 基于规则与语义对代码库进行全面分析，建立结构索引，识别架构热点，并为新需求与未来演化提供可执行的架构建议。",
                "",
                "它不是单纯的命令行评分器，而是把项目结构、边界风险、热点问题与优化方向整理成一套可继续交给 Codex / Claude 使用的架构视图。",
                "",
                "## 推荐安装方式",
                "",
                "```bash",
                "curl -fsSL https://www.architec.top/downloads/latest/install_prod.sh -o install_prod.sh && bash install_prod.sh",
                "```",
                "",
                "Linux 和 macOS 用户默认都使用同一条安装命令。安装器会自动识别当前系统与 CPU 架构，并选择对应的编译发布包。",
                "",
                "The same install command is used on Linux and macOS. The installer auto-detects the current platform and fetches the matching compiled release archive.",
                "",
                "安装器会自动：",
                "",
                "- 安装 `archi`",
                "- 安装开源依赖 `hippocampus` 和 `llmgateway`",
                "- 生成默认配置模板",
                "- 把命令放入本机可执行路径",
                "- 自动按当前平台选择编译包",
                "",
                "## 安装后使用",
                "",
                "1. 登录授权：",
                "",
                "```bash",
                "archi login",
                "```",
                "",
                "2. 在项目根目录建立结构上下文：",
                "",
                "```bash",
                "hippo .",
                "archi .",
                "```",
                "",
                "3. 重启 Codex / Claude，让 skill 同步完成，再基于 Archi 结果做优化、评审、拆分与演化决策。",
                "",
                "## 常用命令",
                "",
                "```bash",
                "archi --version",
                "archi --help",
                "archi login",
                "archi update",
                "hippo .",
                "archi .",
                "```",
                "",
                "## 输出结果",
                "",
                "- `.hippocampus/`",
                "  保存项目结构索引、签名抽取、依赖关系与基础中间结果",
                "- `.architec/`",
                "  保存架构分析结果、热点判断、可视化与报告输出",
                "",
                "## 当前发布资产",
                "",
                *asset_lines,
                "- `SHA256SUMS.txt`",
                "",
                "## 说明",
                "",
                "- GitHub Releases 负责分发安装包和版本资产",
                "- 官网负责注册、登录、授权、账号状态和设备管理",
                "- 本地项目分析仍然在用户自己的机器上进行",
                "- 功能介绍页：<https://www.architec.top/how-it-works>",
                f"- Release repository: https://github.com/{repo}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return target


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build release artifacts and checksums for Architec.")
    parser.add_argument("--python", default=sys.executable, help="Python executable to use for packaging.")
    parser.add_argument("--repo", default="bfly123/architec-releases", help="GitHub release repo for notes.")
    parser.add_argument("--no-clean", action="store_true", help="Keep existing dist/ contents before building.")
    parser.add_argument(
        "--with-nuitka",
        action="store_true",
        help="Also build a compiled standalone binary archive with Nuitka.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    version = read_version()
    run_build(args.python, clean=not args.no_clean)
    build_dependency_wheels(args.python)
    build_skills_archive()
    if args.with_nuitka:
        run_nuitka_build(args.python)
    checksum_file = write_checksums(version)
    notes_file = write_release_notes(version, args.repo)
    print(f"Built Architec {version} release artifacts in {DIST}")
    print(f"Wrote {checksum_file.name} and {notes_file.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
