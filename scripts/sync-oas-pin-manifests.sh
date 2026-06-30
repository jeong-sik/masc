#!/usr/bin/env bash
# Sync MASC's OAS pin manifests from scripts/oas-agent-sdk-pin.sh.
#
# The pin script is the SSOT for the SDK URL, tracking ref, pinned SHA, and
# dependency floor.  This helper only rewrites dependent repository manifests.
# The OAS API surface fingerprint is deliberately opt-in: regenerating it can
# hide a real upstream contract change unless the consumer diff has been
# reviewed first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK_ONLY=0
UPDATE_SURFACE=0

usage() {
  cat <<'EOF'
Usage: scripts/sync-oas-pin-manifests.sh [--check] [--surface]

Options:
  --check     Verify generated OAS pin manifests are up to date.
  --surface   Also check/regenerate scripts/oas-api-surface.json.
              In write mode this runs oas-drift-check.sh --regenerate.
  -h, --help  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --surface)
      UPDATE_SURFACE=1
      shift
      ;;
    -h | --help)
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

source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"

rel_path() {
  local file="$1"
  case "${file}" in
    "${REPO_ROOT}"/*) printf '%s' "${file#"${REPO_ROOT}/"}" ;;
    *) printf '%s' "${file}" ;;
  esac
}

ensure_single_match() {
  local file="$1" pattern="$2" label="$3" count
  count="$(grep -Ec "${pattern}" "${file}" || true)"
  if [[ "${count}" != "1" ]]; then
    echo "${label}: expected exactly one manifest row in $(rel_path "${file}"), found ${count}" >&2
    return 1
  fi
}

write_or_check() {
  local file="$1" tmp_file="$2"
  local rel
  rel="$(rel_path "${file}")"

  if cmp -s "${file}" "${tmp_file}"; then
    rm -f "${tmp_file}"
    return 0
  fi

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    echo "out of sync: ${rel}" >&2
    echo "repair: bash scripts/sync-oas-pin-manifests.sh" >&2
    rm -f "${tmp_file}"
    return 1
  fi

  mv "${tmp_file}" "${file}"
  echo "updated: ${rel}"
}

sync_dune_project() {
  local file="${REPO_ROOT}/dune-project"
  local tmp_file
  ensure_single_match "${file}" '^[[:space:]]*\(agent_sdk \((>=|and \(>=) ' "dune-project agent_sdk floor"
  tmp_file="$(mktemp)"
  sed -E \
    -e "s|^([[:space:]]*\\(agent_sdk \\(and \\(>= )[0-9][0-9.]*\\)(.*)$|\\1${OAS_AGENT_SDK_MIN_VERSION})\\2|" \
    -e "s|^([[:space:]]*\\(agent_sdk \\(>= )[0-9][0-9.]*\\)(.*)$|\\1${OAS_AGENT_SDK_MIN_VERSION})\\2|" \
    "${file}" > "${tmp_file}"
  write_or_check "${file}" "${tmp_file}"
}

sync_opam_manifest() {
  local file="${REPO_ROOT}/masc.opam"
  local tmp_file
  ensure_single_match "${file}" '^[[:space:]]*"agent_sdk" \{' "masc.opam agent_sdk floor"
  tmp_file="$(mktemp)"
  sed -E \
    "s|^([[:space:]]*)\"agent_sdk\" \\{.*$|\\1\"agent_sdk\" {>= \"${OAS_AGENT_SDK_MIN_VERSION}\"}|" \
    "${file}" > "${tmp_file}"
  write_or_check "${file}" "${tmp_file}"
}

trim_line() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

locked_line() {
  local file="$1" pattern="$2" label="$3"
  ensure_single_match "${file}" "${pattern}" "${label}"
  grep -E "${pattern}" "${file}" | trim_line
}

check_locked_opam_manifest() {
  local file="${REPO_ROOT}/masc.opam.locked"
  local dep_line pin_name_line pin_source_line
  local expected_dep_line expected_pin_name_line expected_pin_source_line

  if [[ ! -f "${file}" ]]; then
    echo "masc.opam.locked is missing; regenerate or remove it intentionally" >&2
    return 1
  fi

  dep_line="$(
    locked_line "${file}" '^[[:space:]]*"agent_sdk" \{= "' \
      "masc.opam.locked agent_sdk dependency"
  )"
  pin_name_line="$(
    locked_line "${file}" '^[[:space:]]*"agent_sdk\.[0-9][0-9.]*"' \
      "masc.opam.locked agent_sdk pin-depends package"
  )"
  pin_source_line="$(
    locked_line "${file}" '^[[:space:]]*"git\+https://github[.]com/jeong-sik/oas[.]git#' \
      "masc.opam.locked agent_sdk pin-depends source"
  )"

  expected_dep_line="\"agent_sdk\" {= \"${OAS_AGENT_SDK_MIN_VERSION}\"}"
  expected_pin_name_line="\"agent_sdk.${OAS_AGENT_SDK_MIN_VERSION}\""
  expected_pin_source_line="\"git+${OAS_AGENT_SDK_URL}#${OAS_AGENT_SDK_SHA}\""

  if [[ "${dep_line}" != "${expected_dep_line}" \
     || "${pin_name_line}" != "${expected_pin_name_line}" \
     || "${pin_source_line}" != "${expected_pin_source_line}" ]]; then
    echo "masc.opam.locked is not aligned with scripts/oas-agent-sdk-pin.sh" >&2
    echo "expected dependency: ${expected_dep_line}" >&2
    echo "actual dependency:   ${dep_line}" >&2
    echo "expected pin name:   ${expected_pin_name_line}" >&2
    echo "actual pin name:     ${pin_name_line}" >&2
    echo "expected pin source: ${expected_pin_source_line}" >&2
    echo "actual pin source:   ${pin_source_line}" >&2
    echo "repair: regenerate masc.opam.locked with opam lock after reviewing the full dependency graph" >&2
    return 1
  fi
}

sync_docs() {
  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    bash "${SCRIPT_DIR}/sync-oas-pin-docs.sh" --check
  else
    bash "${SCRIPT_DIR}/sync-oas-pin-docs.sh"
  fi
}

sync_surface() {
  if [[ "${UPDATE_SURFACE}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    bash "${SCRIPT_DIR}/oas-drift-check.sh"
  else
    bash "${SCRIPT_DIR}/oas-drift-check.sh" --regenerate
  fi
}

sync_dune_project
sync_opam_manifest
check_locked_opam_manifest
sync_docs
sync_surface

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  echo "OAS pin manifests match ${OAS_AGENT_SDK_BASE_VERSION} (${OAS_AGENT_SDK_SHA})"
else
  echo "OAS pin manifests synced from scripts/oas-agent-sdk-pin.sh"
  if [[ "${UPDATE_SURFACE}" -eq 0 ]]; then
    echo "OAS API surface fingerprint unchanged; pass --surface only after reviewing upstream surface drift."
  fi
fi
