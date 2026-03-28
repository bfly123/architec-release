#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_REPO="${ARCHITEC_PUBLIC_RELEASE_REPO:-bfly123/architec-releases}"
PUBLIC_REPO_URL="${ARCHITEC_PUBLIC_RELEASE_REPO_URL:-https://github.com/${PUBLIC_REPO}.git}"
TMP_DIR="${ARCHITEC_PUBLIC_RELEASE_TMP_DIR:-$(mktemp -d)}"
README_TEMPLATE="${ARCHITEC_PUBLIC_RELEASE_README_TEMPLATE:-$ROOT_DIR/docs/public-release-readme.md}"
PUSH_CHANGES="${ARCHITEC_PUBLIC_RELEASE_PUSH:-1}"
KEEP_TMP="${ARCHITEC_PUBLIC_RELEASE_KEEP_TMP:-0}"

cleanup() {
  if [[ "${KEEP_TMP}" != "1" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

usage() {
  cat <<'EOF'
Usage: sync_public_release_repo.sh [--no-push] [--keep-tmp]

Sync the public Architec release README into the public GitHub release repository.

Environment overrides:
  ARCHITEC_PUBLIC_RELEASE_REPO
  ARCHITEC_PUBLIC_RELEASE_REPO_URL
  ARCHITEC_PUBLIC_RELEASE_TMP_DIR
  ARCHITEC_PUBLIC_RELEASE_README_TEMPLATE
  ARCHITEC_PUBLIC_RELEASE_PUSH=0|1
  ARCHITEC_PUBLIC_RELEASE_KEEP_TMP=0|1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)
      PUSH_CHANGES="0"
      shift
      ;;
    --keep-tmp)
      KEEP_TMP="1"
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

trap cleanup EXIT

[[ -f "${README_TEMPLATE}" ]] || {
  echo "README template not found: ${README_TEMPLATE}" >&2
  exit 1
}

git clone "${PUBLIC_REPO_URL}" "${TMP_DIR}" >/dev/null 2>&1
cp "${README_TEMPLATE}" "${TMP_DIR}/README.md"

(
  cd "${TMP_DIR}"
  if git diff --quiet -- README.md; then
    echo "Public release README already up to date."
    exit 0
  fi

  git add README.md
  git commit -m "Refresh public release README"

  if [[ "${PUSH_CHANGES}" == "1" ]]; then
    git push origin main
    echo "Pushed README update to ${PUBLIC_REPO}"
  else
    echo "Committed README update locally in ${TMP_DIR}"
  fi
)
