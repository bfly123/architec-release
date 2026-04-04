#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="${ARCHITEC_SOURCE_DIR:-$ROOT_DIR/../architec}"
CLOUD_DIR="${ARCHITEC_CLOUD_DIR:-$ROOT_DIR/../architec-cloud}"
INSTALL_SCRIPT="${ROOT_DIR}/tools/install_prod.sh"
BASE_URL="${ARCHITEC_CLOUD_APP_URL:-http://127.0.0.1:3100}"
DOWNLOAD_BASE_URL="${ARCHITEC_CLOUD_DOWNLOAD_BASE_URL:-${BASE_URL}/downloads/latest}"
RELEASE_REPO="${ARCHITEC_RELEASE_REPO:-bfly123/architec-releases}"
RELEASE_VERSION="${ARCHITEC_RELEASE_VERSION:-latest}"
USE_GITHUB_DOWNLOADS="${ARCHITEC_RELEASE_SMOKE_GITHUB_DOWNLOADS:-0}"
TMP_DIR="$(mktemp -d)"
HOME_DIR="${TMP_DIR}/home"
INSTALL_BASE="${TMP_DIR}/install"
BIN_DIR="${TMP_DIR}/bin"
MANAGED_PYTHON_DIR="${INSTALL_BASE}/python-tools/venv"
PYTHON_USER_BASE="${TMP_DIR}/pyuser"
PYTHON_VENV_DIR="${TMP_DIR}/venv"
CLOUD_DATA_DIR="${TMP_DIR}/cloud-data"
COOKIE_JAR="${TMP_DIR}/cookies.txt"
HEADERS_FILE="${TMP_DIR}/headers.txt"
SERVER_LOG="${TMP_DIR}/web.log"
WHOAMI_JSON="${TMP_DIR}/whoami.json"
STATUS_JSON="${TMP_DIR}/status.json"
DEVICES_JSON="${TMP_DIR}/devices.json"
SESSION_STATUS_JSON="${TMP_DIR}/session-status.json"
SERVER_PID=""

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

cleanup() {
  local status="$?"
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ "${status}" -ne 0 && -f "${SERVER_LOG}" ]]; then
    echo "Release install smoke failed. Recent web server log:" >&2
    tail -n 200 "${SERVER_LOG}" >&2 || true
  fi
  rm -rf "${TMP_DIR}"
  exit "${status}"
}

trap cleanup EXIT INT TERM

header_location() {
  python3 - "$1" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    for raw in handle:
        if raw.lower().startswith("location:"):
            print(raw.split(":", 1)[1].strip())
            break
    else:
        raise SystemExit("location header not found")
PY
}

extract_auth_code() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
from urllib.parse import parse_qs, urljoin, urlparse

base_url, location, expected_state = sys.argv[1:]
complete_url = urljoin(f"{base_url}/", location)
complete_query = parse_qs(urlparse(complete_url).query)
next_url = complete_query.get("next", [""])[0]
if not next_url:
    raise SystemExit("authorization redirect did not include next")
next_query = parse_qs(urlparse(next_url).query)
code = next_query.get("code", [""])[0]
state = next_query.get("state", [""])[0]
if not code:
    raise SystemExit("authorization redirect did not include code")
if state != expected_state:
    raise SystemExit(f"authorization state mismatch: expected {expected_state}, got {state}")
print(code)
PY
}

assert_account_redirect() {
  local location="$1"
  case "${location}" in
    */account|*/account\?*|/account|/account\?*)
      ;;
    *)
      echo "Expected redirect to /account, got: ${location}" >&2
      exit 1
      ;;
  esac
}

wait_for_server() {
  local attempt
  for attempt in $(seq 1 90); do
    if curl -fsS "${BASE_URL}/status" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "${SERVER_PID}" ]] && ! kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
      echo "Web server exited before becoming ready." >&2
      exit 1
    fi
    sleep 1
  done
  echo "Timed out waiting for ${BASE_URL}" >&2
  exit 1
}

need_cmd bash
need_cmd curl
need_cmd pnpm
need_cmd python3

mkdir -p "${HOME_DIR}" "${INSTALL_BASE}" "${BIN_DIR}" "${PYTHON_USER_BASE}" "${CLOUD_DATA_DIR}"
python3 -m venv "${PYTHON_VENV_DIR}"

resolve_github_release_assets() {
  local version_tag="$1"
  gh release view "${version_tag}" \
    --repo "${RELEASE_REPO}" \
    --json tagName,assets \
    --jq '
      .tagName,
      (.assets[] | select(.name=="SHA256SUMS.txt") | .url),
      (.assets[] | select(.name|test("^hippocampus-.*\\.whl$")) | .url),
      (.assets[] | select(.name|test("^llmgateway-.*\\.whl$")) | .url)
    ' 2>/dev/null
}

echo "Installing cloud dependencies"
(
  cd "${CLOUD_DIR}"
  pnpm install --frozen-lockfile
  pnpm build
)

echo "Starting local auth portal at ${BASE_URL}"
(
  cd "${CLOUD_DIR}"
  ARCHITEC_CLOUD_APP_URL="${BASE_URL}" \
  ARCHITEC_CLOUD_DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL}" \
  ARCHITEC_CLOUD_DATA_DIR="${CLOUD_DATA_DIR}" \
  ./tools/run-e2e-web.sh
) >"${SERVER_LOG}" 2>&1 &
SERVER_PID="$!"

wait_for_server

echo "Running website smoke"
(
  cd "${CLOUD_DIR}"
  ARCHITEC_CLOUD_APP_URL="${BASE_URL}" ./tools/local-smoke.sh
)

EMAIL="release.$(date +%s).$RANDOM@example.com"
PASSWORD="SmokePass123!"
STATE="state-$(date +%s)-$RANDOM"
INSTALL_ID="install-$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)"
DEVICE_NAME="Release Smoke Device"
REDIRECT_URI="http://127.0.0.1:46319/callback"

echo "Registering CLI auth test account ${EMAIL}"
curl -fsS \
  -D "${HEADERS_FILE}" \
  -c "${COOKIE_JAR}" \
  -b "${COOKIE_JAR}" \
  -o /dev/null \
  -X POST \
  -H "content-type: application/x-www-form-urlencoded" \
  --data-urlencode "email=${EMAIL}" \
  --data-urlencode "password=${PASSWORD}" \
  "${BASE_URL}/api/auth/register"

REGISTER_LOCATION="$(header_location "${HEADERS_FILE}")"
assert_account_redirect "${REGISTER_LOCATION}"

echo "Installing release ${RELEASE_VERSION} from ${RELEASE_REPO}"
INSTALL_CMD=(
  bash "${INSTALL_SCRIPT}"
  --version "${RELEASE_VERSION}"
  --repo "${RELEASE_REPO}"
  --install-base "${INSTALL_BASE}"
  --bin-dir "${BIN_DIR}"
  --skip-checksum
)

if [[ "${USE_GITHUB_DOWNLOADS}" == "1" ]]; then
  echo "Using GitHub release assets and bundled dependency wheels"
  if [[ "${RELEASE_VERSION}" == "latest" ]]; then
    echo "ARCHITEC_RELEASE_SMOKE_GITHUB_DOWNLOADS=1 requires ARCHITEC_RELEASE_VERSION to be an explicit tag." >&2
    exit 1
  fi
  mapfile -t GITHUB_RELEASE_INFO < <(resolve_github_release_assets "${RELEASE_VERSION}")
  if [[ "${#GITHUB_RELEASE_INFO[@]}" -lt 4 ]]; then
    echo "Failed to resolve GitHub release assets for ${RELEASE_VERSION}" >&2
    exit 1
  fi
  GITHUB_RELEASE_TAG="${GITHUB_RELEASE_INFO[0]}"
  GITHUB_CHECKSUMS_URL="${GITHUB_RELEASE_INFO[1]}"
  GITHUB_HIPPO_WHEEL_URL="${GITHUB_RELEASE_INFO[2]}"
  GITHUB_LLMGATEWAY_WHEEL_URL="${GITHUB_RELEASE_INFO[3]}"
  GITHUB_BASE_URL="https://github.com/${RELEASE_REPO}/releases/download/${GITHUB_RELEASE_TAG}"
  INSTALL_CMD+=(--base-url "${GITHUB_BASE_URL}")
else
  INSTALL_CMD+=(--base-url "${DOWNLOAD_BASE_URL}" --skip-open-source-deps)
fi

INSTALL_ENV=(
  "HOME=${HOME_DIR}"
  "PATH=${BIN_DIR}:${PYTHON_VENV_DIR}/bin:${PYTHON_USER_BASE}/bin:${PATH}"
  "PYTHONUSERBASE=${PYTHON_USER_BASE}"
  "VIRTUAL_ENV=${PYTHON_VENV_DIR}"
  "ARCHITEC_CONFIGURE_LLM=0"
)
if [[ "${USE_GITHUB_DOWNLOADS}" == "1" ]]; then
  INSTALL_ENV+=("ARCHITEC_HIPPOCAMPUS_WHEEL_URL=${GITHUB_HIPPO_WHEEL_URL}")
  INSTALL_ENV+=("ARCHITEC_LLMGATEWAY_WHEEL_URL=${GITHUB_LLMGATEWAY_WHEEL_URL}")
fi

env "${INSTALL_ENV[@]}" "${INSTALL_CMD[@]}"

if [[ ! -x "${BIN_DIR}/archi" ]]; then
  echo "Installed archi binary not found at ${BIN_DIR}/archi" >&2
  exit 1
fi

if [[ "${USE_GITHUB_DOWNLOADS}" == "1" ]]; then
  if [[ ! -x "${MANAGED_PYTHON_DIR}/bin/python" ]]; then
    echo "Managed Python environment not found at ${MANAGED_PYTHON_DIR}/bin/python" >&2
    exit 1
  fi
  if [[ ! -x "${BIN_DIR}/hippo" ]]; then
    echo "Managed hippo launcher not found at ${BIN_DIR}/hippo" >&2
    exit 1
  fi
  "${MANAGED_PYTHON_DIR}/bin/python" - <<'PY'
import importlib.util

missing = [
    name
    for name in ("hippocampus", "llmgateway")
    if importlib.util.find_spec(name) is None
]
if missing:
    raise SystemExit(f"expected bundled dependency wheels to be installed, missing: {', '.join(missing)}")
PY
fi

echo "Checking fresh install auth status"
HOME="${HOME_DIR}" \
PATH="${BIN_DIR}:${PYTHON_VENV_DIR}/bin:${PYTHON_USER_BASE}/bin:${PATH}" \
PYTHONUSERBASE="${PYTHON_USER_BASE}" \
VIRTUAL_ENV="${PYTHON_VENV_DIR}" \
ARCHITEC_AUTH_BASE_URL="${BASE_URL}" \
archi status --json > "${SESSION_STATUS_JSON}"

CLI_VERSION="$(ARCHITEC_SOURCE_DIR="${SOURCE_DIR}" python3 - "${SESSION_STATUS_JSON}" <<'PY'
import json
import os
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
if payload.get("authenticated") is not False:
    raise SystemExit(f"expected fresh install to be unauthenticated, got: {payload}")
client_version = str(payload.get("client_version", "") or "").strip()
if not client_version:
    source_dir = Path(os.environ["ARCHITEC_SOURCE_DIR"])
    pyproject = source_dir / "pyproject.toml"
    if pyproject.exists():
        try:
            project = tomllib.loads(pyproject.read_text(encoding="utf-8"))
            client_version = str(project.get("project", {}).get("version", "") or "").strip()
        except Exception:
            client_version = ""
print(client_version)
PY
)"

echo "Issuing browserless CLI authorization code"
curl -fsS \
  -D "${HEADERS_FILE}" \
  -c "${COOKIE_JAR}" \
  -b "${COOKIE_JAR}" \
  -o /dev/null \
  -X POST \
  -H "content-type: application/x-www-form-urlencoded" \
  --data-urlencode "state=${STATE}" \
  --data-urlencode "installId=${INSTALL_ID}" \
  --data-urlencode "deviceName=${DEVICE_NAME}" \
  --data-urlencode "redirectUri=${REDIRECT_URI}" \
  --data-urlencode "appVersion=${CLI_VERSION}" \
  "${BASE_URL}/api/cli/authorize"

AUTH_LOCATION="$(header_location "${HEADERS_FILE}")"
AUTH_CODE="$(extract_auth_code "${BASE_URL}" "${AUTH_LOCATION}" "${STATE}")"

echo "Logging in with installed CLI"
HOME="${HOME_DIR}" \
PATH="${BIN_DIR}:${PYTHON_VENV_DIR}/bin:${PYTHON_USER_BASE}/bin:${PATH}" \
PYTHONUSERBASE="${PYTHON_USER_BASE}" \
VIRTUAL_ENV="${PYTHON_VENV_DIR}" \
ARCHITEC_AUTH_BASE_URL="${BASE_URL}" \
archi login \
  --auth-code "${AUTH_CODE}" \
  --install-id "${INSTALL_ID}" \
  --device-name "${DEVICE_NAME}"

echo "Collecting authenticated CLI state"
HOME="${HOME_DIR}" \
PATH="${BIN_DIR}:${PYTHON_VENV_DIR}/bin:${PYTHON_USER_BASE}/bin:${PATH}" \
PYTHONUSERBASE="${PYTHON_USER_BASE}" \
VIRTUAL_ENV="${PYTHON_VENV_DIR}" \
ARCHITEC_AUTH_BASE_URL="${BASE_URL}" \
archi whoami --json > "${WHOAMI_JSON}"

HOME="${HOME_DIR}" \
PATH="${BIN_DIR}:${PYTHON_VENV_DIR}/bin:${PYTHON_USER_BASE}/bin:${PATH}" \
PYTHONUSERBASE="${PYTHON_USER_BASE}" \
VIRTUAL_ENV="${PYTHON_VENV_DIR}" \
ARCHITEC_AUTH_BASE_URL="${BASE_URL}" \
archi status --json > "${STATUS_JSON}"

HOME="${HOME_DIR}" \
PATH="${BIN_DIR}:${PYTHON_VENV_DIR}/bin:${PYTHON_USER_BASE}/bin:${PATH}" \
PYTHONUSERBASE="${PYTHON_USER_BASE}" \
VIRTUAL_ENV="${PYTHON_VENV_DIR}" \
ARCHITEC_AUTH_BASE_URL="${BASE_URL}" \
archi devices --json > "${DEVICES_JSON}"

python3 - "${WHOAMI_JSON}" "${STATUS_JSON}" "${DEVICES_JSON}" "${EMAIL}" "${INSTALL_ID}" "${DEVICE_NAME}" <<'PY'
import json
import sys

whoami_path, status_path, devices_path, expected_email, expected_install_id, expected_device_name = sys.argv[1:]

whoami = json.load(open(whoami_path, "r", encoding="utf-8"))
status = json.load(open(status_path, "r", encoding="utf-8"))
devices = json.load(open(devices_path, "r", encoding="utf-8"))

assert whoami["email"] == expected_email, whoami
assert whoami["install_id"] == expected_install_id, whoami
assert whoami["device_name"] == expected_device_name, whoami
assert whoami["license_active"] is True, whoami
assert whoami["device_revoked"] is False, whoami
if isinstance(whoami.get("upgrade"), dict):
    assert whoami["upgrade"].get("required") is False, whoami

assert status["authenticated"] is True, status
assert status["install_id"] == expected_install_id, status
assert status["device_name"] == expected_device_name, status
if "lease_valid" in status:
    assert status["lease_valid"] is True, status
if isinstance(status.get("upgrade"), dict):
    assert status["upgrade"].get("required") is False, status
if isinstance(status.get("remote"), dict):
    assert status["remote"].get("email") == expected_email, status
    if "license_active" in status["remote"]:
        assert status["remote"]["license_active"] is True, status

matching_device = None
for item in devices:
    install_id = item.get("install_id", item.get("installId"))
    if install_id == expected_install_id:
        matching_device = item
        break

assert matching_device is not None, devices
assert matching_device.get("device_name", matching_device.get("deviceName")) == expected_device_name, matching_device
revoked_at = matching_device.get("revoked_at", matching_device.get("revokedAt"))
assert not revoked_at, matching_device
PY

echo "Checking logout path on installed CLI"
HOME="${HOME_DIR}" \
PATH="${BIN_DIR}:${PYTHON_VENV_DIR}/bin:${PYTHON_USER_BASE}/bin:${PATH}" \
PYTHONUSERBASE="${PYTHON_USER_BASE}" \
VIRTUAL_ENV="${PYTHON_VENV_DIR}" \
ARCHITEC_AUTH_BASE_URL="${BASE_URL}" \
archi logout

HOME="${HOME_DIR}" \
PATH="${BIN_DIR}:${PYTHON_VENV_DIR}/bin:${PYTHON_USER_BASE}/bin:${PATH}" \
PYTHONUSERBASE="${PYTHON_USER_BASE}" \
VIRTUAL_ENV="${PYTHON_VENV_DIR}" \
ARCHITEC_AUTH_BASE_URL="${BASE_URL}" \
archi status --json > "${SESSION_STATUS_JSON}"

python3 - "${SESSION_STATUS_JSON}" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
if payload.get("authenticated") is not False:
    raise SystemExit(f"expected logout to clear auth session, got: {payload}")
PY

echo "Release install smoke passed"
