#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${ARCHITEC_SOURCE_DIR:-$ROOT_DIR/../architec}"
CLOUD_DIR="${ARCHITEC_CLOUD_DIR:-$ROOT_DIR/../architec-cloud}"
REMOTE_NAME="${ARCHITEC_GIT_REMOTE:-origin}"
RELEASE_REPO="${ARCHITEC_RELEASE_REPO:-bfly123/architec-releases}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PUSH_CHANGES="1"
RUN_PYTEST="1"
RUN_WEB_BUILD="1"
RUN_WEB_SMOKE="1"
RUN_RELEASE_SMOKE="1"
PUBLISH_LOCAL="0"
ALLOW_DIRTY="0"
VERSION_OVERRIDE=""
TAG_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: cut_release.sh [options]

Prepare and cut an Architec release from the development repository.

Default behavior:
  1. Verify git worktree is clean
  2. Read version from pyproject.toml and derive tag v<version>
  3. Run pytest, web build, web smoke, and release-install smoke
  4. Create a local git tag if it does not already exist
  5. Push the current branch and tag to the configured remote

Options:
  --version <version>         Override version from pyproject.toml
  --tag <tag>                 Override git tag, default: v<version>
  --no-push                   Do not push branch or tag
  --skip-pytest               Skip PYTHONPATH=src pytest -q
  --skip-web-build            Skip architec-cloud pnpm build
  --skip-web-smoke            Skip architec-cloud pnpm smoke
  --skip-release-smoke        Skip bash tools/release_install_smoke.sh
  --publish-local             After checks, run tools/publish_release.sh locally
  --allow-dirty               Allow running with a dirty git worktree
  --help                      Show this message

Environment overrides:
  ARCHITEC_GIT_REMOTE
  ARCHITEC_RELEASE_REPO
  PYTHON_BIN
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

read_version() {
  "${PYTHON_BIN}" - <<'PY'
import tomllib
from pathlib import Path

payload = tomllib.loads(Path("pyproject.toml").read_text(encoding="utf-8"))
print(str(payload["project"]["version"]).strip())
PY
}

ensure_clean_worktree() {
  if [[ "${ALLOW_DIRTY}" == "1" ]]; then
    return 0
  fi
  local status
  status="$(git status --short)"
  if [[ -n "${status}" ]]; then
    echo "Git worktree is dirty. Commit or stash changes first, or pass --allow-dirty." >&2
    printf '%s\n' "${status}" >&2
    exit 1
  fi
}

current_branch() {
  git rev-parse --abbrev-ref HEAD
}

tag_exists_local() {
  git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1
}

tag_exists_remote() {
  git ls-remote --exit-code --tags "${REMOTE_NAME}" "refs/tags/$1" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION_OVERRIDE="${2:-}"
      shift 2
      ;;
    --tag)
      TAG_OVERRIDE="${2:-}"
      shift 2
      ;;
    --no-push)
      PUSH_CHANGES="0"
      shift
      ;;
    --skip-pytest)
      RUN_PYTEST="0"
      shift
      ;;
    --skip-web-build)
      RUN_WEB_BUILD="0"
      shift
      ;;
    --skip-web-smoke)
      RUN_WEB_SMOKE="0"
      shift
      ;;
    --skip-release-smoke)
      RUN_RELEASE_SMOKE="0"
      shift
      ;;
    --publish-local)
      PUBLISH_LOCAL="1"
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY="1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

need_cmd git
need_cmd "${PYTHON_BIN}"
if [[ "${RUN_WEB_BUILD}" == "1" || "${RUN_WEB_SMOKE}" == "1" ]]; then
  need_cmd pnpm
fi
if [[ "${PUBLISH_LOCAL}" == "1" ]]; then
  need_cmd gh
fi

cd "${SOURCE_DIR}"

ensure_clean_worktree

VERSION="${VERSION_OVERRIDE}"
if [[ -z "${VERSION}" ]]; then
  VERSION="$(read_version)"
fi
if [[ -z "${VERSION}" ]]; then
  echo "Release version is empty." >&2
  exit 1
fi

TAG="${TAG_OVERRIDE:-v${VERSION}}"
BRANCH="$(current_branch)"

echo "Cutting release from ${SOURCE_DIR}"
echo "Version: ${VERSION}"
echo "Tag: ${TAG}"
echo "Branch: ${BRANCH}"
echo "Remote: ${REMOTE_NAME}"
echo "Release repo: ${RELEASE_REPO}"
echo "Cloud repo: ${CLOUD_DIR}"
echo "Release tooling: ${ROOT_DIR}"

if [[ "${RUN_PYTEST}" == "1" ]]; then
  echo "Running pytest"
  PYTHONPATH=src "${PYTHON_BIN}" -m pytest -q
fi

if [[ "${RUN_WEB_BUILD}" == "1" ]]; then
  echo "Running web build"
  (
    cd "${CLOUD_DIR}"
    pnpm build
  )
fi

if [[ "${RUN_WEB_SMOKE}" == "1" ]]; then
  echo "Running web smoke"
  (
    cd "${CLOUD_DIR}"
    pnpm smoke
  )
fi

if [[ "${RUN_RELEASE_SMOKE}" == "1" ]]; then
  echo "Running release-install smoke"
  ARCHITEC_SOURCE_DIR="${SOURCE_DIR}" \
  ARCHITEC_CLOUD_DIR="${CLOUD_DIR}" \
  bash "${ROOT_DIR}/tools/release_install_smoke.sh"
fi

if tag_exists_local "${TAG}"; then
  echo "Local tag already exists: ${TAG}"
else
  echo "Creating local tag ${TAG}"
  git tag "${TAG}"
fi

if [[ "${PUSH_CHANGES}" == "1" ]]; then
  echo "Pushing branch ${BRANCH} to ${REMOTE_NAME}"
  git push "${REMOTE_NAME}" "${BRANCH}"
  if tag_exists_remote "${TAG}"; then
    echo "Remote tag already exists: ${TAG}"
  else
    echo "Pushing tag ${TAG} to ${REMOTE_NAME}"
    git push "${REMOTE_NAME}" "${TAG}"
  fi
else
  echo "Skipping git push (--no-push)"
fi

if [[ "${PUBLISH_LOCAL}" == "1" ]]; then
  echo "Publishing release assets directly to ${RELEASE_REPO}"
  ARCHITEC_VERSION="${VERSION}" \
  ARCHITEC_VERSION_TAG="${TAG}" \
  ARCHITEC_RELEASE_REPO="${RELEASE_REPO}" \
  ARCHITEC_SOURCE_DIR="${SOURCE_DIR}" \
  bash "${ROOT_DIR}/tools/publish_release.sh"
fi

echo "Release cut complete"
if [[ "${PUSH_CHANGES}" == "1" ]]; then
  echo "Next step: monitor GitHub Actions for tag ${TAG}"
else
  echo "Next step: push ${BRANCH} and ${TAG} manually when ready"
fi
