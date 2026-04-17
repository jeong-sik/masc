#!/usr/bin/env bash
# Fingerprints OAS's public type surfaces (Event_bus payload variants,
# Http_client error variants, Metrics.t record fields) and diffs against
# the committed scripts/oas-api-surface.json.
#
# Purpose: when OAS adds/removes/renames a variant or field, MASC's
# consumer-side pattern matches break. CI catches the compile error
# eventually, but the information arrives late and scattered across N
# files. This script reports the surface delta at pin-bump time, before
# the build fails, so authors can plan consumer adjustments deliberately
# rather than reactively.
#
# Usage:
#   scripts/oas-drift-check.sh               # check; exit 0 match / 2 drift / 1 error
#   scripts/oas-drift-check.sh --regenerate  # rewrite fingerprint from pinned SHA source
#   scripts/oas-drift-check.sh --print       # print current surfaces, no diff
#
# Source resolution (first hit wins):
#   1. $AGENT_SDK_LOCAL_REPO if a git checkout at the pinned SHA
#   2. git fetch into temp bare clone (reuses check-oas-pin.sh pattern)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FINGERPRINT_FILE="${REPO_ROOT}/scripts/oas-api-surface.json"

# shellcheck source=oas-agent-sdk-pin.sh
source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"

MODE="check"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --regenerate) MODE="regenerate"; shift ;;
    --print)      MODE="print"; shift ;;
    -h|--help)
      sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Source resolution
# ---------------------------------------------------------------------------

resolve_source_dir() {
  local out_var="$1"

  # Candidate local repo paths, checked in order:
  #   1. $AGENT_SDK_LOCAL_REPO (explicit opt-in)
  #   2. Sibling checkout: <masc-mcp-parent>/oas
  #   3. Workspace convention: $HOME/me/workspace/yousleepwhen/oas
  # Each must be a git checkout at the pinned SHA to qualify.
  local masc_parent
  masc_parent="$(cd "${REPO_ROOT}/.." && pwd)"
  local -a candidates=(
    "${AGENT_SDK_LOCAL_REPO:-}"
    "${masc_parent}/oas"
    "${HOME}/me/workspace/yousleepwhen/oas"
  )
  local candidate head
  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" && -d "${candidate}" ]] || continue
    git -C "${candidate}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    head="$(git -C "${candidate}" rev-parse HEAD 2>/dev/null || true)"
    if [[ "${head}" == "${OAS_AGENT_SDK_SHA}" ]]; then
      printf -v "${out_var}" '%s' "${candidate}"
      return 0
    fi
  done

  # If $AGENT_SDK_LOCAL_REPO was set but at the wrong SHA, that's a
  # deliberate override — surface it so the user can fix the checkout
  # rather than silently falling through to network fetch.
  if [[ -n "${AGENT_SDK_LOCAL_REPO:-}" ]] \
     && git -C "${AGENT_SDK_LOCAL_REPO}" rev-parse --is-inside-work-tree \
        >/dev/null 2>&1; then
    local wrong_head
    wrong_head="$(git -C "${AGENT_SDK_LOCAL_REPO}" rev-parse HEAD 2>/dev/null || true)"
    echo "AGENT_SDK_LOCAL_REPO=${AGENT_SDK_LOCAL_REPO} is at ${wrong_head:-unknown}, expected ${OAS_AGENT_SDK_SHA}" >&2
    return 1
  fi

  # Fallback: temp clone from upstream URL
  local scratch
  scratch="$(mktemp -d -t oas-drift-src.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '${scratch}'" EXIT

  if ! GIT_DIR="${scratch}/bare" git init -q --bare; then
    echo "git init bare failed" >&2; return 1
  fi
  if ! GIT_DIR="${scratch}/bare" git fetch -q --no-tags --depth=1 \
         "${OAS_AGENT_SDK_URL}" "${OAS_AGENT_SDK_SHA}" 2>/dev/null; then
    echo "git fetch of ${OAS_AGENT_SDK_SHA} from ${OAS_AGENT_SDK_URL} failed" >&2
    return 1
  fi
  mkdir -p "${scratch}/tree"
  if ! GIT_DIR="${scratch}/bare" git archive --format=tar FETCH_HEAD \
        | tar -x -C "${scratch}/tree"; then
    echo "git archive extract failed" >&2
    return 1
  fi
  printf -v "${out_var}" '%s' "${scratch}/tree"
}

# ---------------------------------------------------------------------------
# Surface extraction
# ---------------------------------------------------------------------------

# Event_bus payload variants live as `  | VariantName of { ... }` inside the
# `type payload = ` block in lib/event_bus.ml.
extract_event_bus_variants() {
  local src="$1"
  local file="${src}/lib/event_bus.ml"
  [[ -f "${file}" ]] || { echo "missing ${file}" >&2; return 1; }
  awk '
    /^type payload/ { inblock=1; next }
    inblock && /^(and|type|let|module) / { inblock=0 }
    inblock && /^  \| [A-Z]/ {
      sub(/^  \| /, ""); sub(/[[:space:]].*/, "");
      print
    }
  ' "${file}" | sort -u
}

# Http_client error variants from the .mli type http_error.
extract_http_error_variants() {
  local src="$1"
  local file="${src}/lib/llm_provider/http_client.mli"
  [[ -f "${file}" ]] || { echo "missing ${file}" >&2; return 1; }
  awk '
    /^type http_error/ { inblock=1; next }
    inblock && /^(and|type|val|let|module) / { inblock=0 }
    inblock && /^  \| [A-Z]/ {
      sub(/^  \| /, ""); sub(/[[:space:]].*/, "");
      print
    }
  ' "${file}" | sort -u
}

# Metrics.t record fields from the .mli type t.
extract_metrics_fields() {
  local src="$1"
  local file="${src}/lib/llm_provider/metrics.mli"
  [[ -f "${file}" ]] || { echo "missing ${file}" >&2; return 1; }
  awk '
    /^type t = \{/ { inblock=1; next }
    inblock && /^\}/ { inblock=0 }
    inblock && /^  [a-z_]+:/ {
      sub(/:.*/, ""); sub(/^[[:space:]]+/, "");
      print
    }
  ' "${file}" | sort -u
}

lines_to_json_array() {
  # stdin: one entry per line; stdout: JSON array
  jq -R . | jq -s .
}

build_fingerprint() {
  local src="$1"
  local ebv hev mf
  ebv="$(extract_event_bus_variants   "${src}" | lines_to_json_array)"
  hev="$(extract_http_error_variants  "${src}" | lines_to_json_array)"
  mf="$( extract_metrics_fields       "${src}" | lines_to_json_array)"

  jq -n \
    --arg sha "${OAS_AGENT_SDK_SHA}" \
    --arg ver "${OAS_AGENT_SDK_BASE_VERSION}" \
    --argjson ebv "${ebv}" \
    --argjson hev "${hev}" \
    --argjson mf  "${mf}" \
    '{
       pinned_sha:        $sha,
       pinned_version:    $ver,
       surfaces: {
         event_bus_payload_variants: $ebv,
         http_error_variants:        $hev,
         metrics_fields:             $mf
       }
     }'
}

# ---------------------------------------------------------------------------
# Diff
# ---------------------------------------------------------------------------

diff_arrays_added() {
  jq -cn --argjson a "$2" --argjson b "$1" '($a - $b) | sort'
}
diff_arrays_removed() {
  jq -cn --argjson a "$2" --argjson b "$1" '($b - $a) | sort'
}

report_diff() {
  local section_name="$1" prev_arr="$2" curr_arr="$3"
  local added removed
  added="$(diff_arrays_added   "${prev_arr}" "${curr_arr}")"
  removed="$(diff_arrays_removed "${prev_arr}" "${curr_arr}")"
  local added_count removed_count
  added_count="$(jq 'length' <<<"${added}")"
  removed_count="$(jq 'length' <<<"${removed}")"

  if (( added_count == 0 && removed_count == 0 )); then
    return 0
  fi

  echo
  echo "  [${section_name}]"
  if (( added_count > 0 )); then
    echo "    added:"
    jq -r '.[] | "      + " + .' <<<"${added}"
  fi
  if (( removed_count > 0 )); then
    echo "    removed:"
    jq -r '.[] | "      - " + .' <<<"${removed}"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

src_dir=""
resolve_source_dir src_dir || { echo "cannot locate OAS source at ${OAS_AGENT_SDK_SHA}" >&2; exit 1; }

current="$(build_fingerprint "${src_dir}")"

case "${MODE}" in
  print)
    jq . <<<"${current}"
    exit 0
    ;;
  regenerate)
    printf '%s\n' "${current}" | jq . > "${FINGERPRINT_FILE}"
    echo "wrote fingerprint: ${FINGERPRINT_FILE}"
    exit 0
    ;;
  check)
    if [[ ! -f "${FINGERPRINT_FILE}" ]]; then
      echo "fingerprint file missing: ${FINGERPRINT_FILE}" >&2
      echo "  repair: bash scripts/oas-drift-check.sh --regenerate" >&2
      exit 1
    fi
    prev="$(cat "${FINGERPRINT_FILE}")"

    drift=0
    for section in event_bus_payload_variants http_error_variants metrics_fields; do
      prev_arr="$(jq ".surfaces.${section}" <<<"${prev}")"
      curr_arr="$(jq ".surfaces.${section}" <<<"${current}")"
      if ! report_diff "${section}" "${prev_arr}" "${curr_arr}"; then
        drift=1
      fi
    done

    if (( drift == 0 )); then
      echo "OAS API surface matches fingerprint (pinned_sha=${OAS_AGENT_SDK_SHA})"
      exit 0
    fi

    echo
    echo "OAS API surface drift detected against ${FINGERPRINT_FILE}." >&2
    echo "  Review the delta above against MASC consumer sites:" >&2
    echo "    lib/oas_compat/oas_compat.ml      (Http_client + Metrics — single source)" >&2
    echo "    lib/oas_sse_bridge.ml             (Event_bus payload matches — until adapter covers it)" >&2
    echo
    echo "  Repair flow (after consumer changes compile clean):" >&2
    echo "    bash scripts/oas-drift-check.sh --regenerate" >&2
    echo "    git add scripts/oas-api-surface.json" >&2
    echo "    git commit -m 'chore(oas): refresh API surface fingerprint'" >&2
    echo "    and commit the updated fingerprint." >&2
    exit 2
    ;;
esac
