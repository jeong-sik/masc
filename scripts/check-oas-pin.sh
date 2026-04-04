#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# GitHub release metadata can lag for this repo. Keep the dependency floor
# aligned with the pinned SDK's declared opam version, and ratchet the runtime
# pin against upstream main so CI catches drift immediately.
source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"

min_version_re="${OAS_AGENT_SDK_MIN_VERSION//./\\.}"
default_pin_source="${OAS_AGENT_SDK_URL}#${OAS_AGENT_SDK_SHA}"
pin_source="${AGENT_SDK_PIN_URL:-${default_pin_source}}"

if [[ "${pin_source}" == "${default_pin_source}" ]]; then
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

if grep -Eq '0\.81\.0' \
  "${REPO_ROOT}/docs/KEEPER-USER-MANUAL.md" \
  "${REPO_ROOT}/docs/OAS-UTILIZATION-AUDIT.md"; then
  echo "stale OAS version references remain in keeper/OAS docs" >&2
  exit 1
fi

if [[ "${pin_source}" == "${default_pin_source}" ]]; then
  echo "OAS pin verified: ${OAS_AGENT_SDK_TRACK_REF}@${OAS_AGENT_SDK_SHA} (base tag ${OAS_AGENT_SDK_BASE_TAG})"
else
  echo "OAS pin verified via override: ${pin_source}"
fi
