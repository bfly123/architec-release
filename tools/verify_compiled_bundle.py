#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract a compiled Architec release bundle and verify the binary starts."
    )
    parser.add_argument("archive", help="Path to archi-<os>-<arch>.tar.gz or .zip")
    parser.add_argument(
        "--binary-name",
        default="",
        help="Override the binary name inside the extracted bundle. Defaults to archi or archi.exe based on archive suffix.",
    )
    return parser.parse_args()


def extract_archive(archive_path: Path, target_dir: Path) -> None:
    if archive_path.suffix == ".zip":
        with zipfile.ZipFile(archive_path) as bundle:
            bundle.extractall(target_dir)
        return
    if archive_path.name.endswith(".tar.gz"):
        with tarfile.open(archive_path, "r:gz") as bundle:
            bundle.extractall(target_dir)
        return
    raise SystemExit(f"Unsupported archive type: {archive_path}")


def find_binary(root: Path, binary_name: str) -> Path:
    matches = sorted(path for path in root.rglob(binary_name) if path.is_file())
    if not matches:
        raise SystemExit(f"Compiled archi binary not found after extraction: {binary_name}")
    return matches[0]


def verify_certifi_bundle(root: Path) -> None:
    matches = sorted(path for path in root.rglob("certifi/cacert.pem") if path.is_file())
    if not matches:
        raise SystemExit("Compiled bundle is missing certifi/cacert.pem, so TLS fallback cannot work.")


def verify_embedded_source_tree(root: Path) -> None:
    matches = sorted(path for path in root.rglob("src/architec/__init__.py") if path.is_file())
    if not matches:
        raise SystemExit("Compiled bundle is missing src/architec, so bundled helper scripts cannot import architec.")


def verify_status_output(binary_path: Path, work_dir: Path) -> None:
    status_path = work_dir / "status.json"
    isolated_home = work_dir / "home"
    isolated_home.mkdir(parents=True, exist_ok=True)
    env = {
        **os.environ,
        "HOME": str(isolated_home),
        "USERPROFILE": str(isolated_home),
        "ARCHITEC_USER_CONFIG_DIR": str(isolated_home / ".architec"),
        "LLMGATEWAY_USER_CONFIG_DIR": str(isolated_home / ".llmgateway"),
        "HIPPOCAMPUS_USER_CONFIG_DIR": str(isolated_home / ".hippocampus"),
    }
    result = subprocess.run(
        [str(binary_path), "status", "--json"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    if result.returncode != 0:
        raise SystemExit(
            "Compiled archi binary failed to start.\n"
            f"Binary: {binary_path}\n"
            f"Exit code: {result.returncode}\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )
    status_path.write_text(result.stdout, encoding="utf-8")
    payload = json.loads(result.stdout)
    if payload.get("authenticated") is not False:
        raise SystemExit(f"Unexpected startup status payload: {payload}")


def main() -> int:
    args = parse_args()
    archive_path = Path(args.archive).resolve()
    if not archive_path.is_file():
        raise SystemExit(f"Archive not found: {archive_path}")

    binary_name = args.binary_name.strip()
    if not binary_name:
        binary_name = "archi.exe" if archive_path.suffix == ".zip" else "archi"

    with tempfile.TemporaryDirectory(prefix="archi-bundle-check-") as tmp:
        tmp_dir = Path(tmp)
        extract_archive(archive_path, tmp_dir)
        verify_certifi_bundle(tmp_dir)
        verify_embedded_source_tree(tmp_dir)
        binary_path = find_binary(tmp_dir, binary_name)
        verify_status_output(binary_path, tmp_dir)

    print(f"Verified compiled bundle startup: {archive_path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
