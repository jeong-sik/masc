#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/check-oas-pin.sh [--local-only]

Options:
  --local-only   Skip upstream remote drift lookup and verify only repository
                 manifests plus the current local opam switch.
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-only)
      LOCAL_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# GitHub release metadata can lag for this repo. Keep the dependency floor
# aligned with the pinned SDK's declared opam version, and ratchet the runtime
# pin against upstream main so CI catches drift immediately.
source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"

min_version_re="${OAS_AGENT_SDK_MIN_VERSION//./\\.}"
default_pin_source="${OAS_AGENT_SDK_URL}#${OAS_AGENT_SDK_SHA}"
pin_source="${AGENT_SDK_PIN_URL:-${default_pin_source}}"
expected_opam_pin_source="git+${OAS_AGENT_SDK_URL}#${OAS_AGENT_SDK_SHA}"
# Ambient local checkouts are not authoritative for doctor runs.
# Only validate a local OAS checkout when the caller explicitly opts in.
local_oas_checkout="${AGENT_SDK_LOCAL_REPO:-}"

if [[ "${pin_source}" == "${default_pin_source}" ]]; then
  if [[ "${LOCAL_ONLY}" -eq 0 ]]; then
    latest_main_sha="$(
      git ls-remote "${OAS_AGENT_SDK_URL}" "refs/heads/${OAS_AGENT_SDK_TRACK_REF}" \
        | awk '{print $1}'
    )"

    if [[ -z "${latest_main_sha}" ]]; then
      echo "failed to resolve upstream ${OAS_AGENT_SDK_TRACK_REF} SHA" >&2
      exit 1
    fi

    if [[ "${OAS_AGENT_SDK_SHA}" != "${latest_main_sha}" ]]; then
      echo "::warning::OAS main drift: pinned ${OAS_AGENT_SDK_SHA}, upstream ${latest_main_sha} — update pin when API-compatible"
    fi
  fi
else
  echo "OAS pin override in use: ${pin_source}"
fi

if ! grep -Eq "\\(agent_sdk \\(>= ${min_version_re}\\)\\)" "${REPO_ROOT}/dune-project"; then
  echo "dune-project agent_sdk floor is not ${OAS_AGENT_SDK_MIN_VERSION}" >&2
  exit 1
fi

if ! grep -Eq "\"agent_sdk\" \\{>= \"${min_version_re}\"\\}" "${REPO_ROOT}/masc_mcp.opam"; then
  echo "masc_mcp.opam agent_sdk floor is not ${OAS_AGENT_SDK_MIN_VERSION}" >&2
  exit 1
fi

if ! bash "${SCRIPT_DIR}/sync-oas-pin-docs.sh" --check; then
  echo "OAS pin generated doc blocks are not aligned with scripts/oas-agent-sdk-pin.sh" >&2
  exit 1
fi

if [[ "${pin_source}" == "${default_pin_source}" ]]; then
  if [[ -n "${local_oas_checkout}" ]] \
    && git -C "${local_oas_checkout}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local_checkout_head="$(git -C "${local_oas_checkout}" rev-parse HEAD 2>/dev/null || true)"
    if [[ "${local_checkout_head}" != "${OAS_AGENT_SDK_SHA}" ]]; then
      echo "local oas checkout drift: ${local_oas_checkout}@${local_checkout_head:-unknown}, expected ${OAS_AGENT_SDK_SHA}" >&2
      echo "repair: git -C \"${local_oas_checkout}\" checkout ${OAS_AGENT_SDK_SHA} # or pin that checkout explicitly via AGENT_SDK_PIN_URL" >&2
      exit 1
    fi
  elif [[ -n "${AGENT_SDK_LOCAL_REPO:-}" ]]; then
    echo "AGENT_SDK_LOCAL_REPO is not a git checkout: ${local_oas_checkout}" >&2
    exit 1
  fi
fi

# Portable semver comparison: returns 0 (true) if $1 >= $2.
# Handles 3-part versions (major.minor.patch); missing parts default to 0.
version_gte() {
  local IFS='.'
  # shellcheck disable=SC2206
  local a=($1) b=($2)
  local i
  for i in 0 1 2; do
    local va=${a[$i]:-0} vb=${b[$i]:-0}
    if (( va > vb )); then return 0; fi
    if (( va < vb )); then return 1; fi
  done
  return 0
}

if command -v opam >/dev/null 2>&1; then
  installed_packages="$(opam exec -- opam list --installed --columns=name,version --short 2>/dev/null)"
  installed_version="$(awk '$1 == "agent_sdk" { print $2 }' <<<"${installed_packages}")"
  if [[ -z "${installed_version}" ]]; then
    echo "agent_sdk is not installed in the current opam switch" >&2
    echo "repair: bash scripts/opam-pin-external-deps.sh && opam install . --deps-only --with-test --with-doc -y" >&2
    exit 1
  fi
  if ! version_gte "${installed_version}" "${OAS_AGENT_SDK_MIN_VERSION}"; then
    echo "installed agent_sdk version is ${installed_version}, expected >= ${OAS_AGENT_SDK_MIN_VERSION}" >&2
    echo "repair: bash scripts/opam-pin-external-deps.sh && opam install . --deps-only --with-test --with-doc -y" >&2
    exit 1
  fi

  pin_list_output="$(opam exec -- opam pin list 2>/dev/null || true)"
  pin_line="$(awk '$1 ~ /^agent_sdk\./ { print }' <<<"${pin_list_output}")"
  if [[ -n "${pin_line}" ]]; then
    installed_pin_source="$(awk '{print $3}' <<<"${pin_line}")"
    case "${installed_pin_source}" in
      "${expected_opam_pin_source}")
        ;;
      git+file://*)
        local_pin_path="${installed_pin_source#git+file://}"
        local_pin_path="${local_pin_path%%#*}"
        local_pin_head="$(git -C "${local_pin_path}" rev-parse HEAD 2>/dev/null || true)"
        if [[ "${local_pin_head}" != "${OAS_AGENT_SDK_SHA}" ]]; then
          echo "local agent_sdk pin points to ${local_pin_path}@${local_pin_head:-unknown}, expected ${OAS_AGENT_SDK_SHA}" >&2
          echo "repair: bash scripts/opam-pin-external-deps.sh" >&2
          exit 1
        fi
        ;;
      *)
        echo "agent_sdk pin source is ${installed_pin_source}, expected ${expected_opam_pin_source}" >&2
        echo "repair: bash scripts/opam-pin-external-deps.sh" >&2
        exit 1
        ;;
    esac
  elif [[ "${LOCAL_ONLY}" -eq 0 ]]; then
    echo "WARN: could not read agent_sdk pin source from opam; installed version ${installed_version} satisfies floor ${OAS_AGENT_SDK_MIN_VERSION}" >&2
  fi
fi

if [[ "${pin_source}" == "${default_pin_source}" ]]; then
  echo "OAS pin verified: ${OAS_AGENT_SDK_TRACK_REF}@${OAS_AGENT_SDK_SHA} (base version ${OAS_AGENT_SDK_BASE_VERSION})"
else
  echo "OAS pin verified via override: ${pin_source}"
fi
