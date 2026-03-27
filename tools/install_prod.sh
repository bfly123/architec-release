#!/usr/bin/env bash

set -euo pipefail

REPO="${ARCHITEC_RELEASE_REPO:-bfly123/architec-releases}"
VERSION="${ARCHITEC_VERSION:-latest}"
BASE_URL="${ARCHITEC_DOWNLOAD_BASE_URL:-}"
FALLBACK_BASE_URL="${ARCHITEC_FALLBACK_DOWNLOAD_BASE_URL:-}"
INSTALL_BASE="${ARCHITEC_INSTALL_BASE:-$HOME/.local/architec}"
BIN_DIR="${ARCHITEC_BIN_DIR:-$HOME/.local/bin}"
VERIFY_CHECKSUMS="${ARCHITEC_VERIFY_CHECKSUMS:-1}"
INSTALL_OPEN_SOURCE_DEPS="${ARCHITEC_INSTALL_OPEN_SOURCE_DEPS:-1}"
CONFIGURE_LLM="${ARCHITEC_CONFIGURE_LLM:-auto}"
HIPPOCAMPUS_GIT_URL="${ARCHITEC_HIPPOCAMPUS_GIT_URL:-git+https://github.com/bfly123/hippocampus.git@main}"
LLMGATEWAY_GIT_URL="${ARCHITEC_LLMGATEWAY_GIT_URL:-git+https://github.com/bfly123/llmgateway.git@main}"
HIPPOCAMPUS_WHEEL_URL="${ARCHITEC_HIPPOCAMPUS_WHEEL_URL:-}"
LLMGATEWAY_WHEEL_URL="${ARCHITEC_LLMGATEWAY_WHEEL_URL:-}"
RAW_OS_NAME="${ARCHITEC_TARGET_OS:-$(uname -s)}"
RAW_ARCH_NAME="${ARCHITEC_TARGET_ARCH:-$(uname -m)}"
OS_NAME=""
ARCH_NAME=""
ASSET_NAME="${ARCHITEC_ASSET_NAME:-}"
PACKAGE_MANAGER="${ARCHITEC_SYSTEM_PACKAGE_MANAGER:-}"
PACKAGE_UPDATE_DONE="0"

USER_CONFIG_BASE="${ARCHITEC_USER_CONFIG_DIR:-$HOME/.architec}"
STATE_DIR="${USER_CONFIG_BASE}"
if [[ -n "${ARCHITEC_LLM_CONFIG:-}" ]]; then
  LLM_CONFIG_PATH="${ARCHITEC_LLM_CONFIG}"
else
  LLM_CONFIG_PATH="${STATE_DIR}/config.yaml"
fi
LLM_CONFIG_BASE="$(dirname "${LLM_CONFIG_PATH}")"

LLMGATEWAY_USER_CONFIG_BASE="${LLMGATEWAY_USER_CONFIG_DIR:-$HOME/.llmgateway}"
if [[ -n "${LLMGATEWAY_CONFIG:-}" ]]; then
  LLMGATEWAY_CONFIG_PATH="${LLMGATEWAY_CONFIG}"
else
  LLMGATEWAY_CONFIG_PATH="${LLMGATEWAY_USER_CONFIG_BASE}/config.yaml"
fi
LLMGATEWAY_CONFIG_BASE="$(dirname "${LLMGATEWAY_CONFIG_PATH}")"

gateway_provider_type="${gateway_provider_type:-${architec_llm_provider_type:-}}"
gateway_api_style="${gateway_api_style:-${architec_llm_api_style:-}}"
gateway_base_url="${gateway_base_url:-${architec_llm_main_url:-}}"
gateway_api_key="${gateway_api_key:-${architec_llm_main_api_key:-}}"
gateway_max_concurrent="${gateway_max_concurrent:-${architec_llm_max_concurrent:-}}"
gateway_model_map_json="${gateway_model_map_json:-}"
gateway_retry_max="${gateway_retry_max:-}"
gateway_timeout="${gateway_timeout:-}"
architec_llm_strong_model="${architec_llm_strong_model:-}"
architec_llm_weak_model="${architec_llm_weak_model:-}"
architec_llm_strong_reasoning_effort="${architec_llm_strong_reasoning_effort:-}"
architec_llm_weak_reasoning_effort="${architec_llm_weak_reasoning_effort:-}"

usage() {
  cat <<'EOF'
Usage: install_prod.sh [options]

Install the compiled Architec release artifact from GitHub Releases, check the
local environment, auto-install the open-source dependencies hippocampus and
llmgateway when possible, and optionally guide the user through initial
llmgateway API configuration.

Options:
  --version <tag|latest>     Release tag to install. Default: latest
  --repo <owner/name>        Release repository. Default: bfly123/architec-releases
  --base-url <url>           Direct download base URL. Example: https://host/downloads/latest
  --install-base <path>      Installation base directory. Default: ~/.local/architec
  --bin-dir <path>           Directory where the archi symlink is created. Default: ~/.local/bin
  --os <name>                Override detected operating system
  --arch <name>              Override detected architecture
  --asset-name <name>        Override the release asset name
  --skip-checksum            Skip SHA256SUMS verification
  --skip-open-source-deps    Skip installing hippocampus and llmgateway from git
  --configure-llm            Force interactive or env-driven llmgateway setup
  --skip-llm-config          Do not prompt for llmgateway API setup
  --help                     Show this message

Environment overrides:
  ARCHITEC_RELEASE_REPO
  ARCHITEC_VERSION
  ARCHITEC_DOWNLOAD_BASE_URL
  ARCHITEC_FALLBACK_DOWNLOAD_BASE_URL
  ARCHITEC_INSTALL_BASE
  ARCHITEC_BIN_DIR
  ARCHITEC_TARGET_OS
  ARCHITEC_TARGET_ARCH
  ARCHITEC_ASSET_NAME
  ARCHITEC_VERIFY_CHECKSUMS=0
  ARCHITEC_INSTALL_OPEN_SOURCE_DEPS=0
  ARCHITEC_CONFIGURE_LLM=auto|1|0
  ARCHITEC_HIPPOCAMPUS_GIT_URL
  ARCHITEC_LLMGATEWAY_GIT_URL
  ARCHITEC_HIPPOCAMPUS_WHEEL_URL
  ARCHITEC_LLMGATEWAY_WHEEL_URL
  ARCHITEC_SYSTEM_PACKAGE_MANAGER
  ARCHITEC_USER_CONFIG_DIR
  ARCHITEC_LLM_CONFIG
  LLMGATEWAY_USER_CONFIG_DIR
  LLMGATEWAY_CONFIG
  architec_llm_provider_type
  architec_llm_api_style
  architec_llm_main_url
  architec_llm_main_api_key
  architec_llm_max_concurrent
  architec_llm_strong_model
  architec_llm_weak_model
  architec_llm_strong_reasoning_effort
  architec_llm_weak_reasoning_effort
  GITHUB_TOKEN / GH_TOKEN    Optional GitHub API token for higher rate limits
EOF
}

say() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

falsy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|n|off)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_os() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    linux)
      printf 'linux'
      ;;
    darwin|macos|macosx|osx)
      printf 'macos'
      ;;
    mingw*|msys*|cygwin*|windows|win32|win64)
      printf 'windows'
      ;;
    *)
      printf '%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
      ;;
  esac
}

normalize_arch() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    x86_64|amd64)
      printf 'x86_64'
      ;;
    arm64|aarch64)
      printf 'arm64'
      ;;
    *)
      printf '%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
      ;;
  esac
}

default_asset_name() {
  if [[ "$1" == "windows" ]]; then
    printf 'archi-%s-%s.zip' "$1" "$2"
  else
    printf 'archi-%s-%s.tar.gz' "$1" "$2"
  fi
}

detect_package_manager() {
  if [[ -n "${PACKAGE_MANAGER}" ]]; then
    printf '%s' "${PACKAGE_MANAGER}"
    return 0
  fi
  local candidate
  for candidate in apt-get dnf yum pacman apk brew; do
    if have_cmd "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  printf ''
}

packages_for_command() {
  local command_name="$1"
  local manager="$2"
  case "${command_name}:${manager}" in
    python3:apt-get) printf 'python3 python3-pip python3-venv' ;;
    python3:dnf) printf 'python3 python3-pip' ;;
    python3:yum) printf 'python3 python3-pip' ;;
    python3:pacman) printf 'python python-pip' ;;
    python3:apk) printf 'python3 py3-pip' ;;
    python3:brew) printf 'python' ;;
    pip:apt-get) printf 'python3-pip' ;;
    pip:dnf) printf 'python3-pip' ;;
    pip:yum) printf 'python3-pip' ;;
    pip:pacman) printf 'python-pip' ;;
    pip:apk) printf 'py3-pip' ;;
    pip:brew) printf 'python' ;;
    node:apt-get|nodejs:apt-get|npm:apt-get) printf 'nodejs npm' ;;
    node:dnf|nodejs:dnf|npm:dnf) printf 'nodejs npm' ;;
    node:yum|nodejs:yum|npm:yum) printf 'nodejs npm' ;;
    node:pacman|nodejs:pacman|npm:pacman) printf 'nodejs npm' ;;
    node:apk|nodejs:apk|npm:apk) printf 'nodejs npm' ;;
    node:brew|nodejs:brew|npm:brew) printf 'node npm' ;;
    git:apt-get|git:dnf|git:yum|git:pacman|git:apk|git:brew) printf 'git' ;;
    curl:apt-get|curl:dnf|curl:yum|curl:pacman|curl:apk|curl:brew) printf 'curl' ;;
    tar:apt-get|tar:dnf|tar:yum|tar:pacman|tar:apk|tar:brew) printf 'tar' ;;
    unzip:apt-get|unzip:dnf|unzip:yum|unzip:pacman|unzip:apk|unzip:brew) printf 'unzip' ;;
    *) printf '' ;;
  esac
}

manual_install_hint() {
  local command_name="$1"
  local manager
  manager="$(detect_package_manager)"
  local packages
  packages="$(packages_for_command "${command_name}" "${manager}")"
  case "${manager}" in
    apt-get)
      printf 'sudo apt-get update && sudo apt-get install -y %s' "${packages:-<package>}"
      ;;
    dnf)
      printf 'sudo dnf install -y %s' "${packages:-<package>}"
      ;;
    yum)
      printf 'sudo yum install -y %s' "${packages:-<package>}"
      ;;
    pacman)
      printf 'sudo pacman -Sy --noconfirm %s' "${packages:-<package>}"
      ;;
    apk)
      printf 'sudo apk add %s' "${packages:-<package>}"
      ;;
    brew)
      printf 'brew install %s' "${packages:-<package>}"
      ;;
    *)
      printf 'Install %s with your system package manager' "${command_name}"
      ;;
  esac
}

run_package_install() {
  local manager="$1"
  shift
  local prefix=()
  if [[ "$(id -u)" -ne 0 && "${manager}" != "brew" ]]; then
    if have_cmd sudo; then
      prefix=(sudo)
    else
      return 1
    fi
  fi
  case "${manager}" in
    apt-get)
      if [[ "${PACKAGE_UPDATE_DONE}" != "1" ]]; then
        "${prefix[@]}" apt-get update
        PACKAGE_UPDATE_DONE="1"
      fi
      "${prefix[@]}" apt-get install -y "$@"
      ;;
    dnf)
      "${prefix[@]}" dnf install -y "$@"
      ;;
    yum)
      "${prefix[@]}" yum install -y "$@"
      ;;
    pacman)
      "${prefix[@]}" pacman -Sy --noconfirm "$@"
      ;;
    apk)
      "${prefix[@]}" apk add "$@"
      ;;
    brew)
      brew install "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

install_system_dependency() {
  local command_name="$1"
  local manager
  manager="$(detect_package_manager)"
  if [[ -z "${manager}" ]]; then
    return 1
  fi
  local packages
  packages="$(packages_for_command "${command_name}" "${manager}")"
  if [[ -z "${packages}" ]]; then
    return 1
  fi
  local package_list=()
  read -r -a package_list <<<"${packages}"
  warn "Missing '${command_name}'. Trying to install it via ${manager}: ${packages}"
  run_package_install "${manager}" "${package_list[@]}"
}

ensure_command() {
  local command_name="$1"
  if have_cmd "${command_name}"; then
    return 0
  fi
  if install_system_dependency "${command_name}" && have_cmd "${command_name}"; then
    return 0
  fi
  die "Could not install '${command_name}' automatically. Please install it manually and re-run. Suggested command: $(manual_install_hint "${command_name}")"
}

ensure_python_version() {
  python3 - <<'PY'
import sys

if sys.version_info < (3, 11):
    raise SystemExit(
        f"Architec requires Python 3.11 or newer for the helper dependencies. "
        f"Detected {sys.version.split()[0]}."
    )
PY
}

ensure_python_pip() {
  if python3 -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  warn "python3 is available but pip is missing. Trying python3 -m ensurepip."
  if python3 -m ensurepip --upgrade >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  if install_system_dependency pip && python3 -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  die "python3 -m pip is still unavailable. Please install pip manually and re-run. Suggested command: $(manual_install_hint pip)"
}

python_package_available() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
from importlib import metadata
import sys

package_name = sys.argv[1]
try:
    metadata.distribution(package_name)
except metadata.PackageNotFoundError:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

python_can_use_user_site() {
  python3 - <<'PY'
import sys

in_virtualenv = bool(
    getattr(sys, "real_prefix", None)
    or sys.prefix != getattr(sys, "base_prefix", sys.prefix)
)
raise SystemExit(1 if in_virtualenv else 0)
PY
}

install_python_git_package() {
  local label="$1"
  local module_name="$2"
  local git_url="$3"
  local pip_args=()

  if python_can_use_user_site; then
    pip_args+=(--user)
  fi

  pip_args+=(--upgrade --force-reinstall)
  pip_args+=(--find-links "${TMP_DIR}")

  say "Installing or upgrading open-source dependency: ${label}"
  say "Source: ${git_url}"
  if ! python3 -m pip install "${pip_args[@]}" "${git_url}"; then
    die "Failed to install ${label} from ${git_url}. Please fix Python/network/build dependencies and re-run."
  fi
}

install_python_wheel_package() {
  local label="$1"
  local module_name="$2"
  local wheel_url="$3"
  local wheel_name
  wheel_name="$(basename "${wheel_url%%\?*}")"
  local wheel_path="${TMP_DIR}/${wheel_name}"
  local pip_args=()
  local pip_targets=()
  local extra_wheel=""

  if python_can_use_user_site; then
    pip_args+=(--user)
  fi

  pip_args+=(--upgrade --force-reinstall)
  pip_targets+=("${wheel_path}")

  say "Installing or upgrading open-source dependency: ${label}"
  say "Wheel source: ${wheel_url}"
  curl -fL "${wheel_url}" -o "${wheel_path}" || die "Failed to download ${label} wheel from ${wheel_url}"
  for extra_wheel in "${TMP_DIR}"/*.whl; do
    [[ -e "${extra_wheel}" ]] || continue
    [[ "${extra_wheel}" == "${wheel_path}" ]] && continue
    pip_targets+=("${extra_wheel}")
  done
  python3 -m pip install "${pip_args[@]}" "${pip_targets[@]}" || die "Failed to install ${label} from wheel ${wheel_url}"
}

install_python_dependency() {
  local label="$1"
  local module_name="$2"
  local wheel_url="$3"
  local git_url="$4"

  if [[ -n "${wheel_url}" ]]; then
    install_python_wheel_package "${label}" "${module_name}" "${wheel_url}"
    return 0
  fi

  install_python_git_package "${label}" "${module_name}" "${git_url}"
}

install_open_source_dependencies() {
  if [[ "${INSTALL_OPEN_SOURCE_DEPS}" == "0" ]]; then
    say "Skipping hippocampus and llmgateway installation"
    return 0
  fi
  say "Architec also uses two open-source Python packages:"
  say "- hippocampus"
  say "- llmgateway"
  say "The installer will prefer bundled release wheels when available, then fall back to git sources."
  if [[ -z "${HIPPOCAMPUS_WHEEL_URL}" || -z "${LLMGATEWAY_WHEEL_URL}" ]]; then
    ensure_command git
  fi
  install_python_dependency "llmgateway" "llmgateway" "${LLMGATEWAY_WHEEL_URL}" "${LLMGATEWAY_GIT_URL}"
  install_python_dependency "hippocampus" "hippocampus" "${HIPPOCAMPUS_WHEEL_URL}" "${HIPPOCAMPUS_GIT_URL}"
}

repomix_install_prefix() {
  printf '%s' "${ARCHITEC_NODE_TOOLS_DIR:-${INSTALL_BASE}/node-tools}"
}

install_repomix() {
  local prefix
  prefix="$(repomix_install_prefix)"
  local package_dir="${prefix}/repomix"
  local package_bin="${package_dir}/node_modules/.bin/repomix"
  local existing_bin=""

  if have_cmd repomix; then
    existing_bin="$(command -v repomix || true)"
    mkdir -p "${BIN_DIR}"
    if [[ -n "${existing_bin}" && ! -x "${BIN_DIR}/repomix" ]]; then
      if ! ln -sf "${existing_bin}" "${BIN_DIR}/repomix" 2>/dev/null; then
        cp -f "${existing_bin}" "${BIN_DIR}/repomix"
      fi
    fi
    say "repomix is already available in PATH"
    return 0
  fi
  if [[ -x "${BIN_DIR}/repomix" ]]; then
    say "repomix launcher already exists at ${BIN_DIR}/repomix"
    return 0
  fi

  ensure_command node
  ensure_command npm

  mkdir -p "${package_dir}" "${BIN_DIR}"

  say "Installing repository structure helper: repomix"
  if ! npm install --prefix "${package_dir}" --no-fund --no-audit repomix; then
    die "Failed to install repomix automatically. Please ensure Node.js and npm work, then re-run. Suggested command: npm install --prefix \"${package_dir}\" repomix"
  fi

  if [[ ! -x "${package_bin}" ]]; then
    die "repomix installation completed but the binary is missing at ${package_bin}"
  fi

  if ! ln -sf "${package_bin}" "${BIN_DIR}/repomix" 2>/dev/null; then
    cp -f "${package_bin}" "${BIN_DIR}/repomix"
  fi

  say "Installed repomix launcher ${BIN_DIR}/repomix"
}

resolve_github_release_metadata() {
  local asset_name="$1"
  local api_url=""

  if [[ "${VERSION}" == "latest" ]]; then
    api_url="https://api.github.com/repos/${REPO}/releases?per_page=30"
  else
    api_url="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
  fi

  local curl_args=(-fsSL)
  local github_api_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "${github_api_token}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${github_api_token}")
    curl_args+=(-H "X-GitHub-Api-Version: 2022-11-28")
  fi

  local release_json=""
  release_json="$(curl "${curl_args[@]}" "${api_url}")" || return 1

  RELEASE_JSON="${release_json}" python3 - "${asset_name}" "${VERSION}" <<'PY'
import json
import os
import re
import sys

asset_name = sys.argv[1]
version_hint = str(sys.argv[2] or "").strip()
payload = json.loads(os.environ["RELEASE_JSON"])


def stable_semver_key(tag_name: str):
    match = re.match(r"^v?(\d+(?:\.\d+)*)$", tag_name)
    if match is None:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def select_release(raw_payload):
    if isinstance(raw_payload, dict):
        return raw_payload
    if not isinstance(raw_payload, list):
        raise SystemExit("unexpected GitHub API release payload shape")

    candidates = []
    for item in raw_payload:
        if not isinstance(item, dict):
            continue
        if bool(item.get("draft")) or bool(item.get("prerelease")):
            continue
        tag_text = str(item.get("tag_name", "") or "").strip()
        version_key = stable_semver_key(tag_text)
        if version_key is None:
            continue
        candidates.append((version_key, item))

    if candidates:
        candidates.sort(key=lambda pair: pair[0], reverse=True)
        return candidates[0][1]

    for item in raw_payload:
        if not isinstance(item, dict):
            continue
        if bool(item.get("draft")) or bool(item.get("prerelease")):
            continue
        return item

    raise SystemExit(
        f"no stable release entries found for version selector {version_hint or '<empty>'}"
    )


release = select_release(payload)
tag_name = str(release.get("tag_name", "") or "").strip()
download_url = ""
checksums_url = ""
hippocampus_wheel_url = ""
llmgateway_wheel_url = ""

for item in release.get("assets", []):
    name = str(item.get("name", "") or "").strip()
    url = str(item.get("browser_download_url", "") or "").strip()
    if name == asset_name:
        download_url = url
    elif name == "SHA256SUMS.txt":
        checksums_url = url
    elif re.match(r"^hippocampus-.*\.whl$", name):
        hippocampus_wheel_url = url
    elif re.match(r"^llmgateway-.*\.whl$", name):
        llmgateway_wheel_url = url

if not tag_name:
    raise SystemExit("release tag missing from GitHub API response")

print(tag_name, download_url, checksums_url, hippocampus_wheel_url, llmgateway_wheel_url)
PY
}

prompt_with_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local value="${!var_name:-}"

  if ! is_interactive; then
    if [[ -z "${value}" ]]; then
      value="${default_value}"
    fi
    printf -v "${var_name}" '%s' "${value}"
    return 0
  fi

  read -r -p "${prompt_text}" value
  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi
  printf -v "${var_name}" '%s' "${value}"
}

prompt_secret_with_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local value=""

  if ! is_interactive; then
    if [[ -n "${!var_name:-}" ]]; then
      return 0
    fi
    printf -v "${var_name}" '%s' "${default_value}"
    return 0
  fi

  read -r -s -p "${prompt_text}" value
  echo
  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi
  printf -v "${var_name}" '%s' "${value}"
}

prompt_yes_no() {
  local prompt_text="$1"
  local default_value="${2:-y}"
  local reply=""

  if ! is_interactive; then
    truthy "${default_value}"
    return $?
  fi

  read -r -p "${prompt_text}" reply
  if [[ -z "${reply}" ]]; then
    reply="${default_value}"
  fi
  truthy "${reply}"
}

load_existing_gateway_config() {
  if [[ ! -f "${LLMGATEWAY_CONFIG_PATH}" ]]; then
    return 0
  fi

  local loaded=""
  loaded="$(python3 - "${LLMGATEWAY_CONFIG_PATH}" <<'PY'
import json
import sys

import yaml

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = yaml.safe_load(handle) or {}

provider = payload.get("provider") or {}
settings = payload.get("settings") or {}

print(
    "\t".join(
        [
            str(provider.get("provider_type", "") or "").strip(),
            str(provider.get("api_style", "") or "").strip(),
            str(provider.get("base_url", "") or "").strip(),
            str(provider.get("api_key", "") or "").strip(),
            str(settings.get("max_concurrent", "") or "").strip(),
            json.dumps(dict(provider.get("model_map") or {}), ensure_ascii=True, sort_keys=True),
            str(settings.get("retry_max", "") or "").strip(),
            str(settings.get("timeout", "") or "").strip(),
            str(settings.get("strong_model", "") or "").strip(),
            str(settings.get("weak_model", "") or "").strip(),
            str(settings.get("strong_reasoning_effort", "") or "").strip().lower(),
            str(settings.get("weak_reasoning_effort", "") or "").strip().lower(),
        ]
    )
)
PY
)"

  local loaded_provider_type loaded_api_style loaded_url loaded_key loaded_max_concurrent loaded_model_map loaded_retry_max loaded_timeout loaded_strong_model loaded_weak_model loaded_strong_effort loaded_weak_effort
  IFS=$'\t' read -r loaded_provider_type loaded_api_style loaded_url loaded_key loaded_max_concurrent loaded_model_map loaded_retry_max loaded_timeout loaded_strong_model loaded_weak_model loaded_strong_effort loaded_weak_effort <<<"${loaded}"

  if [[ -z "${gateway_provider_type:-}" && -n "${loaded_provider_type}" ]]; then
    gateway_provider_type="${loaded_provider_type}"
  fi
  if [[ -z "${gateway_api_style:-}" && -n "${loaded_api_style}" ]]; then
    gateway_api_style="${loaded_api_style}"
  fi
  if [[ -z "${gateway_base_url:-}" && -n "${loaded_url}" ]]; then
    gateway_base_url="${loaded_url}"
  fi
  if [[ -z "${gateway_api_key:-}" && -n "${loaded_key}" ]]; then
    gateway_api_key="${loaded_key}"
  fi
  if [[ -z "${gateway_max_concurrent:-}" && -n "${loaded_max_concurrent}" ]]; then
    gateway_max_concurrent="${loaded_max_concurrent}"
  fi
  if [[ -z "${gateway_model_map_json:-}" && -n "${loaded_model_map}" ]]; then
    gateway_model_map_json="${loaded_model_map}"
  fi
  if [[ -z "${gateway_retry_max:-}" && -n "${loaded_retry_max}" ]]; then
    gateway_retry_max="${loaded_retry_max}"
  fi
  if [[ -z "${gateway_timeout:-}" && -n "${loaded_timeout}" ]]; then
    gateway_timeout="${loaded_timeout}"
  fi
  if [[ -z "${architec_llm_strong_model:-}" && -n "${loaded_strong_model}" ]]; then
    architec_llm_strong_model="${loaded_strong_model}"
  fi
  if [[ -z "${architec_llm_weak_model:-}" && -n "${loaded_weak_model}" ]]; then
    architec_llm_weak_model="${loaded_weak_model}"
  fi
  if [[ -z "${architec_llm_strong_reasoning_effort:-}" && -n "${loaded_strong_effort}" ]]; then
    architec_llm_strong_reasoning_effort="${loaded_strong_effort}"
  fi
  if [[ -z "${architec_llm_weak_reasoning_effort:-}" && -n "${loaded_weak_effort}" ]]; then
    architec_llm_weak_reasoning_effort="${loaded_weak_effort}"
  fi
}

apply_llm_defaults() {
  gateway_provider_type="${gateway_provider_type:-openai}"
  gateway_api_style="${gateway_api_style:-openai_chat}"
  gateway_max_concurrent="${gateway_max_concurrent:-4}"
  gateway_retry_max="${gateway_retry_max:-2}"
  gateway_timeout="${gateway_timeout:-120}"
  architec_llm_strong_model="${architec_llm_strong_model:-gpt-5.4}"
  architec_llm_weak_model="${architec_llm_weak_model:-gpt-5.4-mini}"
  architec_llm_strong_reasoning_effort="${architec_llm_strong_reasoning_effort:-high}"
  architec_llm_weak_reasoning_effort="${architec_llm_weak_reasoning_effort:-low}"
}

write_gateway_config() {
  mkdir -p "${LLMGATEWAY_CONFIG_BASE}"
  python3 - "${LLMGATEWAY_CONFIG_PATH}" "${gateway_provider_type}" "${gateway_api_style}" "${gateway_base_url}" "${gateway_api_key}" "${gateway_max_concurrent}" "${gateway_model_map_json}" "${gateway_retry_max}" "${gateway_timeout}" "${architec_llm_strong_model}" "${architec_llm_weak_model}" "${architec_llm_strong_reasoning_effort}" "${architec_llm_weak_reasoning_effort}" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
provider_type = str(sys.argv[2] or "").strip()
api_style = str(sys.argv[3] or "").strip()
base_url = str(sys.argv[4] or "").strip()
api_key = str(sys.argv[5] or "").strip()
max_concurrent = max(1, int(float(sys.argv[6] or 12)))
model_map = json.loads(sys.argv[7]) if sys.argv[7] else {}
retry_max = max(0, int(float(sys.argv[8] or 3)))
timeout = float(sys.argv[9] or 90)
strong_model = str(sys.argv[10] or "").strip()
weak_model = str(sys.argv[11] or "").strip()
strong_reasoning_effort = str(sys.argv[12] or "").strip().lower()
weak_reasoning_effort = str(sys.argv[13] or "").strip().lower()
headers = {}

if not isinstance(model_map, dict):
    model_map = {}


def quoted(text: str) -> str:
    return json.dumps(str(text), ensure_ascii=False)


def render_mapping_block(indent: str, key: str, mapping: dict[str, object]) -> list[str]:
    if not mapping:
        return [f"{indent}{key}: {{}}"]
    lines = [f"{indent}{key}:"]
    for raw_src, raw_dst in mapping.items():
        src = str(raw_src).strip()
        dst = str(raw_dst).strip()
        if not src or not dst:
            continue
        lines.append(f"{indent}  {quoted(src)}: {quoted(dst)}")
    if len(lines) == 1:
        return [f"{indent}{key}: {{}}"]
    return lines


lines = [
    "# llmgateway config for Architec",
    "# Common case: keep provider_type and api_style as-is, then only fill provider.base_url",
    "# and provider.api_key. The settings block already contains the recommended defaults.",
    "# headers usually stays {} unless your provider explicitly requires extra HTTP headers.",
    "# model_map usually stays {} unless your backend expects different model ids.",
    "version: 1",
    "",
    "provider:",
    f"  provider_type: {quoted(provider_type)}",
    f"  api_style: {quoted(api_style)}",
    f"  base_url: {quoted(base_url)}",
    f"  api_key: {quoted(api_key)}",
    *render_mapping_block("  ", "headers", headers),
    "  # Example when a provider requires extra headers:",
    "  # headers:",
    "  #   anthropic-version: \"2023-06-01\"",
    *render_mapping_block("  ", "model_map", model_map),
    "  # Example when backend model ids differ from the names used by Architec:",
    "  # model_map:",
    "  #   gpt-5.4: openai/gpt-5.4",
    "  #   gpt-5.4-mini: openai/gpt-5.4-mini",
    "",
    "settings:",
    f"  strong_model: {quoted(strong_model)}",
    f"  weak_model: {quoted(weak_model)}",
    f"  strong_reasoning_effort: {quoted(strong_reasoning_effort)}",
    f"  weak_reasoning_effort: {quoted(weak_reasoning_effort)}",
    f"  max_concurrent: {max_concurrent}",
    f"  retry_max: {retry_max}",
    f"  timeout: {timeout}",
    "",
]

config_path.write_text(
    "\n".join(lines),
    encoding="utf-8",
)
PY
  chmod 600 "${LLMGATEWAY_CONFIG_PATH}"
}

write_architec_config() {
  mkdir -p "${LLM_CONFIG_BASE}"
  python3 - "${LLM_CONFIG_PATH}" <<'PY'
import sys
from pathlib import Path

import yaml

config_path = Path(sys.argv[1])
payload = {
    "version": 1,
    "tasks": {
        "architect_history": {"tier": "strong"},
        "architect_feature": {"tier": "strong"},
        "architect_component_scoring": {"tier": "weak"},
        "architect_component_qa": {"tier": "strong"},
        "architect_folder_naming": {"tier": "weak"},
        "architect_topology_review": {"tier": "weak"},
        "architect_full_report_md": {"tier": "strong"},
        "architect_orchestrator": {"tier": "strong"},
        "architec_summary": {"tier": "strong"},
    },
}
config_path.write_text(
    yaml.safe_dump(payload, default_flow_style=False, allow_unicode=True, sort_keys=False),
    encoding="utf-8",
)
PY
  chmod 600 "${LLM_CONFIG_PATH}"
}

seed_global_json_config() {
  local name="$1"
  local src="${TARGET_DIR}/config/${name}"
  local dest="${STATE_DIR}/${name}"

  if [[ ! -f "${src}" ]]; then
    die "Missing bundled config template: ${src}"
  fi

  mkdir -p "${STATE_DIR}"
  if [[ -f "${dest}" ]]; then
    return 0
  fi

  cp "${src}" "${dest}"
  chmod 644 "${dest}"
}

llm_credentials_present() {
  [[ -n "${gateway_base_url:-}" && -n "${gateway_api_key:-}" ]]
}

should_configure_llm_now() {
  if truthy "${CONFIGURE_LLM}"; then
    return 0
  fi
  if falsy "${CONFIGURE_LLM}"; then
    return 1
  fi
  if [[ -f "${LLMGATEWAY_CONFIG_PATH}" ]]; then
    return 0
  fi
  if llm_credentials_present; then
    return 0
  fi
  if is_interactive; then
    if prompt_yes_no "Configure llmgateway API now? [Y/n]: " "y"; then
      return 0
    fi
  fi
  return 1
}

validate_llm_config() {
  python3 - "${LLMGATEWAY_CONFIG_PATH}" "${LLM_CONFIG_PATH}" <<'PY'
import sys
from pathlib import Path

import yaml

gateway_path = Path(sys.argv[1])
architec_path = Path(sys.argv[2])

if not gateway_path.exists():
    raise SystemExit(f"llmgateway config missing: {gateway_path}")
if not architec_path.exists():
    raise SystemExit(f"architec task config missing: {architec_path}")

gateway_payload = yaml.safe_load(gateway_path.read_text(encoding="utf-8")) or {}
architec_payload = yaml.safe_load(architec_path.read_text(encoding="utf-8")) or {}

provider = gateway_payload.get("provider") or {}
settings = gateway_payload.get("settings") or {}
tasks = architec_payload.get("tasks") or {}

problems: list[str] = []
if not str(provider.get("provider_type", "") or "").strip():
    problems.append("provider.provider_type is missing")
if not str(provider.get("api_style", "") or "").strip():
    problems.append("provider.api_style is missing")
if not str(provider.get("base_url", "") or "").strip():
    problems.append("provider.base_url is missing")
if not str(provider.get("api_key", "") or "").strip():
    problems.append("provider.api_key is missing")
if not str(settings.get("strong_model", "") or "").strip():
    problems.append("settings.strong_model is missing")
if not str(settings.get("weak_model", "") or "").strip():
    problems.append("settings.weak_model is missing")
if not tasks:
    problems.append("architec tasks mapping is missing")

if problems:
    raise SystemExit(
        "Architec installer LLM config validation failed:\n- "
        + "\n- ".join(problems)
    )
PY
}

setup_llm_config() {
  seed_global_json_config "rubric.json"
  seed_global_json_config "scoring-policy.json"
  write_architec_config
  load_existing_gateway_config
  apply_llm_defaults

  if should_configure_llm_now; then
    say
    say "LLMGateway setup"
    say "Most users only need to fill the base URL and API key now."
    say "provider_type=${gateway_provider_type}, api_style=${gateway_api_style}"
    prompt_with_default gateway_base_url "LLMGateway base URL [${gateway_base_url:-none}]: " "${gateway_base_url:-}"
    if [[ -n "${gateway_api_key:-}" ]]; then
      prompt_secret_with_default gateway_api_key "LLMGateway API key [press Enter to keep current value]: " "${gateway_api_key}"
    else
      prompt_secret_with_default gateway_api_key "LLMGateway API key [leave blank to fill later]: " ""
    fi
    prompt_with_default gateway_max_concurrent "LLMGateway max concurrent [${gateway_max_concurrent}]: " "${gateway_max_concurrent}"
    prompt_with_default gateway_retry_max "LLMGateway retry max [${gateway_retry_max}]: " "${gateway_retry_max}"
    prompt_with_default gateway_timeout "LLMGateway timeout [${gateway_timeout}]: " "${gateway_timeout}"
    prompt_with_default architec_llm_strong_model "LLMGateway strong model [${architec_llm_strong_model}]: " "${architec_llm_strong_model}"
    prompt_with_default architec_llm_weak_model "LLMGateway weak model [${architec_llm_weak_model}]: " "${architec_llm_weak_model}"
    prompt_with_default architec_llm_strong_reasoning_effort "LLMGateway strong reasoning effort [${architec_llm_strong_reasoning_effort}]: " "${architec_llm_strong_reasoning_effort}"
    prompt_with_default architec_llm_weak_reasoning_effort "LLMGateway weak reasoning effort [${architec_llm_weak_reasoning_effort}]: " "${architec_llm_weak_reasoning_effort}"
    write_gateway_config
    say "Saved llmgateway config to ${LLMGATEWAY_CONFIG_PATH}"
    if llm_credentials_present; then
      validate_llm_config
      say "LLMGateway configuration validated"
    else
      warn "LLMGateway config was saved without base URL or API key. Edit ${LLMGATEWAY_CONFIG_PATH} later, then run: archi --check <repo>"
    fi
    return 0
  fi

  if [[ ! -f "${LLMGATEWAY_CONFIG_PATH}" ]]; then
    write_gateway_config
    warn "Created a starter llmgateway config template at ${LLMGATEWAY_CONFIG_PATH}"
  else
    say "Keeping existing llmgateway config at ${LLMGATEWAY_CONFIG_PATH}"
  fi
  say "Skipped llmgateway API setup for now. Edit ${LLMGATEWAY_CONFIG_PATH} later when you are ready."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --install-base)
      INSTALL_BASE="${2:-}"
      shift 2
      ;;
    --bin-dir)
      BIN_DIR="${2:-}"
      shift 2
      ;;
    --os)
      RAW_OS_NAME="${2:-}"
      shift 2
      ;;
    --arch)
      RAW_ARCH_NAME="${2:-}"
      shift 2
      ;;
    --asset-name)
      ASSET_NAME="${2:-}"
      shift 2
      ;;
    --skip-checksum)
      VERIFY_CHECKSUMS="0"
      shift
      ;;
    --skip-open-source-deps)
      INSTALL_OPEN_SOURCE_DEPS="0"
      shift
      ;;
    --configure-llm)
      CONFIGURE_LLM="1"
      shift
      ;;
    --skip-llm-config)
      CONFIGURE_LLM="0"
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

OS_NAME="$(normalize_os "${RAW_OS_NAME}")"
ARCH_NAME="$(normalize_arch "${RAW_ARCH_NAME}")"
if [[ -z "${ASSET_NAME}" ]]; then
  ASSET_NAME="$(default_asset_name "${OS_NAME}" "${ARCH_NAME}")"
fi

if [[ -z "${VERSION}" || -z "${REPO}" || -z "${INSTALL_BASE}" || -z "${BIN_DIR}" || -z "${ASSET_NAME}" ]]; then
  die "Version, repo, install base, bin dir, and asset name must be non-empty."
fi

BASE_URL="$(printf '%s' "${BASE_URL}" | sed 's#/*$##')"
FALLBACK_BASE_URL="$(printf '%s' "${FALLBACK_BASE_URL}" | sed 's#/*$##')"

say "Checking local environment"
ensure_command curl
ensure_command python3
ensure_python_version
ensure_python_pip
if [[ "${ASSET_NAME}" == *.tar.gz ]]; then
  ensure_command tar
else
  ensure_command unzip
fi

RELEASE_TAG=""
DOWNLOAD_URL=""
CHECKSUMS_URL=""
FALLBACK_DOWNLOAD_URL=""
FALLBACK_CHECKSUMS_URL=""
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [[ -n "${BASE_URL}" ]]; then
  RELEASE_TAG="${VERSION}"
  DOWNLOAD_URL="${BASE_URL}/${ASSET_NAME}"
  CHECKSUMS_URL="${BASE_URL}/SHA256SUMS.txt"
  if [[ -n "${FALLBACK_BASE_URL}" ]]; then
    FALLBACK_DOWNLOAD_URL="${FALLBACK_BASE_URL}/${ASSET_NAME}"
    FALLBACK_CHECKSUMS_URL="${FALLBACK_BASE_URL}/SHA256SUMS.txt"
  fi
else
  say "Resolving Architec release metadata from ${REPO} (${VERSION})"
  read -r RELEASE_TAG DOWNLOAD_URL CHECKSUMS_URL RELEASE_HIPPOCAMPUS_WHEEL_URL RELEASE_LLMGATEWAY_WHEEL_URL < <(
    resolve_github_release_metadata "${ASSET_NAME}"
  )
  if [[ -z "${HIPPOCAMPUS_WHEEL_URL}" ]]; then
    HIPPOCAMPUS_WHEEL_URL="${RELEASE_HIPPOCAMPUS_WHEEL_URL:-}"
  fi
  if [[ -z "${LLMGATEWAY_WHEEL_URL}" ]]; then
    LLMGATEWAY_WHEEL_URL="${RELEASE_LLMGATEWAY_WHEEL_URL:-}"
  fi
fi

if [[ -n "${BASE_URL}" && ( -z "${HIPPOCAMPUS_WHEEL_URL}" || -z "${LLMGATEWAY_WHEEL_URL}" ) ]]; then
  if read -r _RESOLVED_TAG _RESOLVED_DOWNLOAD_URL _RESOLVED_CHECKSUMS_URL RELEASE_HIPPOCAMPUS_WHEEL_URL RELEASE_LLMGATEWAY_WHEEL_URL < <(
    resolve_github_release_metadata "${ASSET_NAME}" 2>/dev/null
  ); then
    if [[ -z "${HIPPOCAMPUS_WHEEL_URL}" ]]; then
      HIPPOCAMPUS_WHEEL_URL="${RELEASE_HIPPOCAMPUS_WHEEL_URL:-}"
    fi
    if [[ -z "${LLMGATEWAY_WHEEL_URL}" ]]; then
      LLMGATEWAY_WHEEL_URL="${RELEASE_LLMGATEWAY_WHEEL_URL:-}"
    fi
  else
    warn "Could not resolve dependency wheel URLs from GitHub release metadata. Falling back to git sources for hippocampus and llmgateway."
  fi
fi

if [[ -z "${RELEASE_TAG}" || -z "${DOWNLOAD_URL}" ]]; then
  die "Failed to resolve release tag or download URL."
fi

install_open_source_dependencies

mkdir -p "${INSTALL_BASE}" "${BIN_DIR}"
install_repomix
ARCHIVE_PATH="${TMP_DIR}/${ASSET_NAME}"
CHECKSUMS_PATH="${TMP_DIR}/SHA256SUMS.txt"

download_with_optional_fallback() {
  local label="$1"
  local output_path="$2"
  local primary_url="$3"
  local fallback_url="${4:-}"

  say "Downloading ${label} from ${primary_url}"
  if curl -fL "${primary_url}" -o "${output_path}"; then
    return 0
  fi
  if [[ -n "${fallback_url}" ]]; then
    warn "Primary download failed for ${label}. Retrying from fallback source: ${fallback_url}"
    curl -fL "${fallback_url}" -o "${output_path}"
    return 0
  fi
  return 1
}

download_with_optional_fallback "${ASSET_NAME}" "${ARCHIVE_PATH}" "${DOWNLOAD_URL}" "${FALLBACK_DOWNLOAD_URL}" || die "Failed to download ${ASSET_NAME}"

if [[ "${VERIFY_CHECKSUMS}" != "0" ]]; then
  if [[ -z "${CHECKSUMS_URL}" ]]; then
    die "SHA256SUMS.txt not found on release ${RELEASE_TAG}. Use --skip-checksum only if you intentionally want to bypass verification."
  fi
  say "Downloading SHA256SUMS.txt for verification"
  download_with_optional_fallback "SHA256SUMS.txt" "${CHECKSUMS_PATH}" "${CHECKSUMS_URL}" "${FALLBACK_CHECKSUMS_URL}" || die "Failed to download SHA256SUMS.txt"
  python3 - "${ARCHIVE_PATH}" "${CHECKSUMS_PATH}" "${ASSET_NAME}" <<'PY'
import hashlib
import sys
from pathlib import Path

archive_path = Path(sys.argv[1])
checksums_path = Path(sys.argv[2])
asset_name = sys.argv[3]

expected = ""
for raw in checksums_path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    if len(parts) >= 2 and parts[-1] == asset_name:
        expected = parts[0].strip()
        break

if not expected:
    raise SystemExit(f"checksum entry not found for {asset_name}")

digest = hashlib.sha256()
with archive_path.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)

actual = digest.hexdigest()
if actual != expected:
    raise SystemExit(
        f"checksum mismatch for {asset_name}: expected {expected}, got {actual}"
    )
PY
  say "Checksum verification passed"
else
  say "Checksum verification skipped"
fi

if [[ "${ASSET_NAME}" == *.zip ]]; then
  python3 - "${ARCHIVE_PATH}" "${TMP_DIR}" <<'PY'
from pathlib import Path
import sys
import zipfile

archive_path = Path(sys.argv[1])
target_dir = Path(sys.argv[2])

with zipfile.ZipFile(archive_path) as archive:
    archive.extractall(target_dir)
PY
else
  tar -xzf "${ARCHIVE_PATH}" -C "${TMP_DIR}"
fi

PACKAGE_DIR="${TMP_DIR}/archi-${OS_NAME}-${ARCH_NAME}"
if [[ ! -d "${PACKAGE_DIR}" ]]; then
  die "Extracted package not found: ${PACKAGE_DIR}"
fi

BINARY_NAME="archi"
if [[ "${OS_NAME}" == "windows" ]]; then
  BINARY_NAME="archi.exe"
fi

TARGET_DIR="${INSTALL_BASE}/${OS_NAME}-${ARCH_NAME}"
rm -rf "${TARGET_DIR}"
mkdir -p "${INSTALL_BASE}"
mv "${PACKAGE_DIR}" "${TARGET_DIR}"
if [[ ! -f "${TARGET_DIR}/${BINARY_NAME}" ]]; then
  die "Installed binary is missing: ${TARGET_DIR}/${BINARY_NAME}"
fi
if ! ln -sf "${TARGET_DIR}/${BINARY_NAME}" "${BIN_DIR}/archi" 2>/dev/null; then
  cp -f "${TARGET_DIR}/${BINARY_NAME}" "${BIN_DIR}/archi"
fi

setup_llm_config

say
say "Installed Architec ${RELEASE_TAG} to ${TARGET_DIR}"
say "Installed launcher ${BIN_DIR}/archi"
say "Binary: ${TARGET_DIR}/${BINARY_NAME}"
if [[ "${INSTALL_OPEN_SOURCE_DEPS}" != "0" ]]; then
  say "Ensured open-source Python dependencies from release wheels or git: hippocampus, llmgateway"
fi
say "Repository structure helper: ${BIN_DIR}/repomix"
say "Architec task config: ${LLM_CONFIG_PATH}"
say "LLMGateway config: ${LLMGATEWAY_CONFIG_PATH}"
if llm_credentials_present; then
  say "Next step: archi login"
else
  say "Next step: fill in ${LLMGATEWAY_CONFIG_PATH}, then run archi login"
fi
