#!/usr/bin/env bash
# Fingerprints OAS's public type surfaces (Event_bus payload variants,
# Http_client error variants, Metrics.t record fields, durable Agent execution
# symbols) and diffs against
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
  #   2. Sibling checkout: <masc-parent>/oas
  # Each must be a git checkout at the pinned SHA to qualify.
  local masc_parent
  masc_parent="$(cd "${REPO_ROOT}/.." && pwd)"
  local -a candidates=(
    "${AGENT_SDK_LOCAL_REPO:-}"
    "${masc_parent}/oas"
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
  if ! GIT_DIR="${scratch}/bare" git fetch -q --no-tags --depth=128 \
         "${OAS_AGENT_SDK_URL}" \
         "+refs/heads/${OAS_AGENT_SDK_TRACK_REF}:refs/heads/${OAS_AGENT_SDK_TRACK_REF}" \
         2>/dev/null; then
    echo "git fetch of ${OAS_AGENT_SDK_TRACK_REF} from ${OAS_AGENT_SDK_URL} failed" >&2
    return 1
  fi
  if ! GIT_DIR="${scratch}/bare" git cat-file -e "${OAS_AGENT_SDK_SHA}^{commit}" \
        2>/dev/null; then
    echo "pinned OAS SHA ${OAS_AGENT_SDK_SHA} is not present in fetched ${OAS_AGENT_SDK_TRACK_REF}" >&2
    return 1
  fi
  mkdir -p "${scratch}/tree"
  if ! GIT_DIR="${scratch}/bare" git archive --format=tar "${OAS_AGENT_SDK_SHA}" \
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
    /^type[[:space:]]+t[[:space:]]*=/ {
      seen=1
      if ($0 ~ /\{/) {
        inblock=1
        sub(/^.*\{/, "")
        print
      }
      next
    }
    seen && !inblock && /^[[:space:]]*\{/ {
      inblock=1
      sub(/^[^{]*\{/, "")
      print
      next
    }
    inblock && /^[[:space:]]*\}/ { exit }
    inblock { print }
  ' "${file}" \
  | sed -n \
      -e 's/^[[:space:]]*;[[:space:]]*\([a-z_][a-zA-Z0-9_]*\)[[:space:]]*:.*/\1/p' \
      -e 's/^[[:space:]]*\([a-z_][a-zA-Z0-9_]*\)[[:space:]]*:.*/\1/p' \
  | sort -u
}

# Durable execution names consumed by MASC's runtime boundary. The compiler
# remains the signature authority; this inventory makes a removed or renamed
# public contract visible during pin review before downstream compilation.
extract_agent_execution_symbols() {
  local src="$1"
  local file="${src}/lib/agent/agent.mli"
  [[ -f "${file}" ]] || { echo "missing ${file}" >&2; return 1; }
  awk '
    function emit_constructor(type_name, text, parts, constructor) {
      sub(/^[[:space:]]*\|?[[:space:]]*/, "", text)
      split(text, parts, /[[:space:]]+/)
      constructor = parts[1]
      if (constructor ~ /^[A-Z][A-Za-z0-9_]*$/) {
        print "constructor:" type_name "." constructor
      }
    }

    /^type / {
      current_type = ""
      if ($2 ~ /^execution_(runtime|store|locator|terminal_outcome|operator_repair_reason|recovery_action|terminal_disposition)$/) {
        current_type = $2
        print "type:" current_type
        if (index($0, "=") > 0) {
          inline_rhs = $0
          sub(/^[^=]*=[[:space:]]*/, "", inline_rhs)
          if (inline_rhs != "" && inline_rhs !~ /^\{/) {
            emit_constructor(current_type, inline_rhs)
          }
        }
      }
      next
    }

    current_type ~ /^execution_(terminal_outcome|operator_repair_reason|recovery_action)$/ && /^[[:space:]]*\|/ {
      emit_constructor(current_type, $0)
      next
    }

    current_type == "execution_terminal_disposition" && /^[[:space:]]*[;{]?[[:space:]]*(outcome|recovery)[[:space:]]*:/ {
      field = $0
      sub(/^[[:space:]]*[;{]?[[:space:]]*/, "", field)
      sub(/[[:space:]]*:.*$/, "", field)
      print "field:execution_terminal_disposition." field
      next
    }

    /^module Execution_projection[[:space:]]*:/ {
      current_type = ""
      print "module:Execution_projection"
      next
    }

    /^val execution_store([[:space:]]|$)/ {
      current_type = ""
      in_execution_store = 1
      print "val:execution_store"
      next
    }

    in_execution_store {
      if (/\?on_scope_ready:/) {
        print "label:execution_store.on_scope_ready"
      }
      if (/\?on_terminal_disposition:/) {
        print "label:execution_store.on_terminal_disposition"
      }
      if (/\?resume:/) {
        print "label:execution_store.resume"
      }
      if (/^[[:space:]]*->[[:space:]]*execution_store[[:space:]]*$/) {
        in_execution_store = 0
      }
      next
    }

    /^val (execution_locator_to_yojson|execution_locator_of_yojson|create_execution_runtime|open_execution_projection)([[:space:]]|$)/ {
      current_type = ""
      print "val:" $2
      next
    }
  ' "${file}" | sort -u
}

lines_to_json_array() {
  # stdin: one entry per line; stdout: JSON array
  jq -R . | jq -s .
}

build_fingerprint() {
  local src="$1"
  local ebv hev mf aes
  ebv="$(extract_event_bus_variants   "${src}" | lines_to_json_array)"
  hev="$(extract_http_error_variants  "${src}" | lines_to_json_array)"
  mf="$( extract_metrics_fields       "${src}" | lines_to_json_array)"
  aes="$(extract_agent_execution_symbols "${src}" | lines_to_json_array)"

  jq -n \
    --arg sha "${OAS_AGENT_SDK_SHA}" \
    --arg ver "${OAS_AGENT_SDK_BASE_VERSION}" \
    --argjson ebv "${ebv}" \
    --argjson hev "${hev}" \
    --argjson mf  "${mf}" \
    --argjson aes "${aes}" \
    '{
       pinned_sha:        $sha,
       pinned_version:    $ver,
       surfaces: {
         event_bus_payload_variants: $ebv,
         http_error_variants:        $hev,
         metrics_fields:             $mf,
         agent_execution_symbols:    $aes
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

report_metadata_diff() {
  local prev="$1" curr="$2"
  local changed=0
  local prev_sha curr_sha prev_ver curr_ver
  prev_sha="$(jq -r '.pinned_sha // ""' <<<"${prev}")"
  curr_sha="$(jq -r '.pinned_sha // ""' <<<"${curr}")"
  prev_ver="$(jq -r '.pinned_version // ""' <<<"${prev}")"
  curr_ver="$(jq -r '.pinned_version // ""' <<<"${curr}")"

  if [[ "${prev_sha}" != "${curr_sha}" || "${prev_ver}" != "${curr_ver}" ]]; then
    echo
    echo "  [fingerprint_metadata]"
  fi
  if [[ "${prev_sha}" != "${curr_sha}" ]]; then
    echo "      ~ pinned_sha: ${prev_sha:-<missing>} -> ${curr_sha:-<missing>}"
    changed=1
  fi
  if [[ "${prev_ver}" != "${curr_ver}" ]]; then
    echo "      ~ pinned_version: ${prev_ver:-<missing>} -> ${curr_ver:-<missing>}"
    changed=1
  fi
  return "${changed}"
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
    if ! report_metadata_diff "${prev}" "${current}"; then
      drift=1
    fi
    for section in event_bus_payload_variants http_error_variants metrics_fields agent_execution_symbols; do
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
    echo "    lib/oas_event_bridge.ml           (Event_bus payload matches — until adapter covers it)" >&2
    echo "    no durable Agent execution consumer is on main yet (tracking masc#25338)" >&2
    echo
    echo "  Repair flow (after consumer changes compile clean):" >&2
    echo "    bash scripts/oas-drift-check.sh --regenerate" >&2
    echo "    git add scripts/oas-api-surface.json" >&2
    echo "    git commit -m 'chore(oas): refresh API surface fingerprint'" >&2
    echo "    and commit the updated fingerprint." >&2
    exit 2
    ;;
esac
