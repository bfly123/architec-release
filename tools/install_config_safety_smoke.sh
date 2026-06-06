#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${ROOT_DIR}/tools/install_prod.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ASSET_DIR="${TMP_DIR}/assets"
PACKAGE_ROOT="${TMP_DIR}/package"
FAKE_BIN="${TMP_DIR}/fake-bin"
mkdir -p "${ASSET_DIR}" "${PACKAGE_ROOT}/archi-linux-x86_64/config" "${FAKE_BIN}"

cat >"${PACKAGE_ROOT}/archi-linux-x86_64/archi" <<'SH'
#!/usr/bin/env bash
echo "fake archi"
SH
chmod +x "${PACKAGE_ROOT}/archi-linux-x86_64/archi"
printf '{}\n' >"${PACKAGE_ROOT}/archi-linux-x86_64/config/rubric.json"
printf '{}\n' >"${PACKAGE_ROOT}/archi-linux-x86_64/config/scoring-policy.json"
tar -C "${PACKAGE_ROOT}" -czf "${ASSET_DIR}/archi-linux-x86_64.tar.gz" archi-linux-x86_64
(
  cd "${ASSET_DIR}"
  sha256sum archi-linux-x86_64.tar.gz >SHA256SUMS.txt
)

cat >"${FAKE_BIN}/repomix" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${FAKE_BIN}/repomix"

run_installer() {
  local home_dir="$1"
  shift
  mkdir -p "${home_dir}"
  HOME="${home_dir}" \
    PATH="${FAKE_BIN}:${PATH}" \
    ARCHITEC_INSTALL_OPEN_SOURCE_DEPS=0 \
    ARCHITEC_INSTALL_SKILLS=0 \
    ARCHITEC_LOGIN_METHOD=browser \
    bash "${INSTALL_SCRIPT}" \
      --base-url "file://${ASSET_DIR}" \
      --install-base "${home_dir}/install" \
      --bin-dir "${home_dir}/bin" \
      --os linux \
      --arch x86_64 \
      "$@" >/dev/null
}

existing_home="${TMP_DIR}/existing-home"
existing_config="${existing_home}/.llmgateway/config.yaml"
mkdir -p "$(dirname "${existing_config}")"
cat >"${existing_config}" <<'YAML'
sentinel: keep-this-file-byte-for-byte
provider:
  api_key: sentinel-not-a-real-secret
YAML
before_hash="$(sha256sum "${existing_config}" | awk '{print $1}')"

architec_llm_main_url="https://env.example.invalid" \
  architec_llm_main_api_key="env-value-must-not-overwrite" \
  run_installer "${existing_home}" --configure-llm

after_hash="$(sha256sum "${existing_config}" | awk '{print $1}')"
if [[ "${before_hash}" != "${after_hash}" ]]; then
  echo "existing llmgateway config changed" >&2
  exit 1
fi

missing_home="${TMP_DIR}/missing-home"
run_installer "${missing_home}" --skip-llm-config
starter_config="${missing_home}/.llmgateway/config.yaml"
if [[ ! -f "${starter_config}" ]]; then
  echo "starter llmgateway config was not created" >&2
  exit 1
fi

mode="$(python3 - "${starter_config}" <<'PY'
import os
import sys

print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])
PY
)"
if [[ "${mode}" != "600" ]]; then
  echo "starter llmgateway config mode is ${mode}, expected 600" >&2
  exit 1
fi

for needle in \
  "providers:" \
  "provider_type:" \
  "api_style:" \
  "base_url:" \
  "api_key:" \
  "headers example" \
  "model_map example" \
  "Optional fallback provider example" \
  "ARCHITEC_LLM_SECONDARY_BASE_URL" \
  "ARCHITEC_LLM_SECONDARY_API_KEY" \
  "fallback_model:" \
  "strong_model:" \
  "weak_model:" \
  "strong_reasoning_effort:" \
  "weak_reasoning_effort:" \
  "max_concurrent:" \
  "retry_max:" \
  "transport_retries:" \
  "timeout:"; do
  if ! grep -q "${needle}" "${starter_config}"; then
    echo "starter llmgateway config missing ${needle}" >&2
    exit 1
  fi
done

echo "install config safety smoke passed"
