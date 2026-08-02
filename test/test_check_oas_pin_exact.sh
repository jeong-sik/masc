#!/usr/bin/env bash
# Regression test: the local preflight must require the repository's exact
# SSOT pin before Dune, including when opam cannot report a pin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/scripts/oas-agent-sdk-pin.sh"
export TEST_AGENT_SDK_VERSION="${OAS_AGENT_SDK_MIN_VERSION}"
export TEST_AGENT_SDK_SHA="${OAS_AGENT_SDK_SHA}"
export TEST_AGENT_SDK_URL="${OAS_AGENT_SDK_URL}"

test_root="$(mktemp -d -t check-oas-pin-exact.XXXXXX)"
trap 'rm -rf "${test_root}"' EXIT
agent_sdk_dir="${test_root}/findlib/agent_sdk"
llm_provider_dir="${test_root}/findlib/llm_provider"
mkdir -p "${test_root}/bin" "${agent_sdk_dir}" "${llm_provider_dir}"

for artifact in agent_sdk.cmi agent_sdk.cmxa agent_sdk.a agent_sdk__Checkpoint.cmi; do
  touch "${agent_sdk_dir}/${artifact}"
done
for artifact in \
  llm_provider.cmi \
  llm_provider.cmxa \
  llm_provider.a \
  llm_provider__Provider_config.cmi \
  llm_provider__Provider_kind.cmi
do
  touch "${llm_provider_dir}/${artifact}"
done

cat >"${test_root}/bin/opam" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  env)
    ;;
  list)
    printf 'agent_sdk %s\n' "${TEST_AGENT_SDK_VERSION}"
    ;;
  show)
    printf '%s\n' "${TEST_AGENT_SDK_VERSION}"
    ;;
  pin)
    case "${TEST_PIN_MODE:-mismatch}" in
      mismatch)
        printf 'agent_sdk.%s git git+%s (at ffffffffffffffffffffffffffffffffffffffff)\n' \
          "${TEST_AGENT_SDK_VERSION}" "${TEST_AGENT_SDK_URL}"
        ;;
      missing)
        ;;
      failure)
        echo 'simulated opam pin list failure' >&2
        exit 17
        ;;
      duplicate)
        printf 'agent_sdk.%s git git+%s (at %s)\n' \
          "${TEST_AGENT_SDK_VERSION}" "${TEST_AGENT_SDK_URL}" "${TEST_AGENT_SDK_SHA}"
        printf 'agent_sdk.%s git git+%s (at ffffffffffffffffffffffffffffffffffffffff)\n' \
          "${TEST_AGENT_SDK_VERSION}" "${TEST_AGENT_SDK_URL}"
        ;;
      exact)
        printf 'agent_sdk.%s git git+%s (at %s)\n' \
          "${TEST_AGENT_SDK_VERSION}" "${TEST_AGENT_SDK_URL}" "${TEST_AGENT_SDK_SHA}"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "${test_root}/bin/opam"

cat >"${test_root}/bin/ocamlfind" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "query" ]] || exit 2
case "\${2:-}" in
  agent_sdk)
    printf '%s\\n' '${agent_sdk_dir}'
    ;;
  agent_sdk.llm_provider)
    printf '%s\\n' '${llm_provider_dir}'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "${test_root}/bin/ocamlfind"

run_rejected_case() {
  local mode="$1"
  local expected_diagnostic="$2"
  local output
  local status

  set +e
  output="$(TEST_PIN_MODE="${mode}" PATH="${test_root}/bin:${PATH}" \
    bash "${REPO_ROOT}/scripts/check-oas-pin.sh" --local-only 2>&1)"
  status=$?
  set -e

  if [[ ${status} -eq 0 ]]; then
    echo "FAIL: ${mode} pin state was accepted" >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected_diagnostic}"* ]]; then
    echo "FAIL: ${mode} rejection diagnostic missing" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
}

run_rejected_case \
  mismatch \
  "agent_sdk pin checkout is ffffffffffffffffffffffffffffffffffffffff, expected ${OAS_AGENT_SDK_SHA}"
run_rejected_case missing "agent_sdk is installed but not pinned"
run_rejected_case failure "failed to read agent_sdk pin source"
run_rejected_case duplicate "agent_sdk pin state is ambiguous"

output="$(TEST_PIN_MODE=exact PATH="${test_root}/bin:${PATH}" \
  bash "${REPO_ROOT}/scripts/check-oas-pin.sh" --local-only 2>&1)"
if [[ "${output}" != *"OAS pin verified: ${OAS_AGENT_SDK_TRACK_REF}@${OAS_AGENT_SDK_SHA}"* ]]; then
  echo "FAIL: exact SSOT pin was not accepted" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

echo "[check-oas-pin-exact test] PASS"
