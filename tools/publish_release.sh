#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${ARCHITEC_SOURCE_DIR:-$ROOT_DIR/../architec}"
RELEASE_REPO="${ARCHITEC_RELEASE_REPO:-bfly123/architec-releases}"
VERSION_TAG="${ARCHITEC_VERSION_TAG:-}"
VERSION="${ARCHITEC_VERSION:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PREBUILT_ARTIFACTS="${ARCHITEC_RELEASE_PREBUILT_ARTIFACTS:-0}"
DIST_DIR="${ARCHITEC_DIST_DIR:-$ROOT_DIR/release-assets}"

if [[ -z "${VERSION}" || -z "${VERSION_TAG}" ]]; then
  read -r VERSION VERSION_TAG < <(ARCHITEC_SOURCE_DIR="${SOURCE_DIR}" "${PYTHON_BIN}" - <<'PY'
import tomllib
import os
from pathlib import Path

source_dir = Path(os.environ["ARCHITEC_SOURCE_DIR"])
payload = tomllib.loads((source_dir / "pyproject.toml").read_text(encoding="utf-8"))
version = str(payload["project"]["version"])
print(version, f"v{version}")
PY
)
fi

cd "${ROOT_DIR}"

wheel_path="${DIST_DIR}/architec-${VERSION}-py3-none-any.whl"
sdist_path="${DIST_DIR}/architec-${VERSION}.tar.gz"
checksums_path="${DIST_DIR}/SHA256SUMS.txt"
install_script_path="${ROOT_DIR}/tools/install_prod.sh"
install_script_ps1_path="${ROOT_DIR}/tools/install_prod.ps1"
skills_archive_path="${DIST_DIR}/architec-skills.tar.gz"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required to publish releases." >&2
  exit 1
fi

if [[ "${PREBUILT_ARTIFACTS}" == "1" ]]; then
  ARCHITEC_SOURCE_DIR="${SOURCE_DIR}" \
  ARCHITEC_DIST_DIR="${DIST_DIR}" \
  "${PYTHON_BIN}" "${ROOT_DIR}/tools/build_release.py" --no-clean --repo "${RELEASE_REPO}"
else
  ARCHITEC_SOURCE_DIR="${SOURCE_DIR}" \
  ARCHITEC_DIST_DIR="${DIST_DIR}" \
  "${PYTHON_BIN}" "${ROOT_DIR}/tools/build_release.py" --with-nuitka --repo "${RELEASE_REPO}"
fi

compiled_artifacts=()
while IFS= read -r path; do
  compiled_artifacts+=("${path}")
done < <(find "${DIST_DIR}" -maxdepth 1 -type f \( -name 'archi-*.tar.gz' -o -name 'archi-*.zip' \) | sort)

if [[ ${#compiled_artifacts[@]} -eq 0 ]]; then
  echo "No compiled artifacts found in ${DIST_DIR}. Expected at least one archi-*.tar.gz or archi-*.zip asset." >&2
  exit 1
fi

dependency_artifacts=()
while IFS= read -r path; do
  dependency_artifacts+=("${path}")
done < <(find "${DIST_DIR}" -maxdepth 1 -type f \( -name 'hippocampus-*.whl' -o -name 'llmgateway-*.whl' \) | sort)

required_assets=(
  "${wheel_path}"
  "${sdist_path}"
  "${checksums_path}"
  "${install_script_path}"
  "${install_script_ps1_path}"
  "${skills_archive_path}"
)
required_assets+=("${compiled_artifacts[@]}")
required_assets+=("${dependency_artifacts[@]}")

for asset in "${required_assets[@]}"; do
  if [[ ! -f "${asset}" ]]; then
    echo "Missing release asset: ${asset}" >&2
    exit 1
  fi
done

if ! gh api "repos/${RELEASE_REPO}" >/dev/null 2>&1; then
  echo "Release repo not found or not accessible: ${RELEASE_REPO}" >&2
  echo "Ensure GH_TOKEN can access ${RELEASE_REPO}. In GitHub Actions this usually means updating the ARCHITEC_RELEASES_TOKEN secret." >&2
  exit 1
fi

if ! gh api "repos/${RELEASE_REPO}/releases/tags/${VERSION_TAG}" >/dev/null 2>&1; then
  gh release create "${VERSION_TAG}" \
    "${wheel_path}" \
    "${sdist_path}" \
    "${checksums_path}" \
    "${install_script_path}" \
    "${install_script_ps1_path}" \
    "${skills_archive_path}" \
    "${compiled_artifacts[@]}" \
    "${dependency_artifacts[@]}" \
    --repo "${RELEASE_REPO}" \
    --title "Architec ${VERSION_TAG}" \
    --notes-file "${DIST_DIR}/RELEASE_NOTES.md"
else
  gh release upload "${VERSION_TAG}" \
    "${wheel_path}" \
    "${sdist_path}" \
    "${checksums_path}" \
    "${install_script_path}" \
    "${install_script_ps1_path}" \
    "${skills_archive_path}" \
    "${compiled_artifacts[@]}" \
    "${dependency_artifacts[@]}" \
    --clobber \
    --repo "${RELEASE_REPO}"
fi

release_id="$(
  gh api "repos/${RELEASE_REPO}/releases/tags/${VERSION_TAG}" --jq '.id'
)"
body="$(cat "${DIST_DIR}/RELEASE_NOTES.md")"
gh api --method PATCH "repos/${RELEASE_REPO}/releases/${release_id}" -f "body=${body}" >/dev/null

echo "Published ${VERSION_TAG} to https://github.com/${RELEASE_REPO}/releases/tag/${VERSION_TAG}"
