#!/usr/bin/env bash
# RFC-0132 PR-3: Boundary_redaction SSOT enforcement.
#
# After RFC-0132 PR-2 (#16536) routed 24 "runtime" public-surface labels
# through Boundary_redaction in cascade/ and keeper/ subsystems, this lint
# blocks regression: any *new* inline "runtime" literal in those files
# must go through the SSOT module.
#
# Scope: the 21 OCaml files PR-2 touched. NOT a repo-wide grep — many
# "runtime" strings elsewhere are JSON schema keys, feature-flag category
# labels, or internal observability and are out of RFC-0132 scope.
#
# Exemption: add `RFC-0132-EXEMPT: <reason>` on the same line or the
# preceding line. The 4 known-exempt sites listed below are pre-approved
# (schema field, classification list, debug format string).
#
# Adding to scope: extend SCAN_FILES when a new subsystem's boundary
# emit-site is routed through Boundary_redaction. Each addition must
# cite the codemod PR in RFC-0132.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MODE="--fail"
case "${1:---fail}" in
  --fail|"") MODE="--fail" ;;
  --print)   MODE="--print" ;;
  -h|--help)
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print]" >&2
    exit 2
    ;;
esac

for tool in rg awk sed; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[no-runtime-literal-outside-boundary-redaction] required tool missing: $tool" >&2
    exit 2
  }
done

# Files routed through Boundary_redaction SSOT by RFC-0132 PR-2 (#16536).
SCAN_FILES=(
  "lib/cascade/cascade_attempt_fsm.ml"
  "lib/cascade/cascade_attempt_liveness_config.ml"
  "lib/cascade/cascade_attempt_liveness_observer.ml"
  "lib/cascade/cascade_catalog_runtime_probe.ml"
  "lib/cascade/cascade_event_bridge.ml"
  "lib/cascade/cascade_legacy_runner.ml"
  "lib/cascade/cascade_runner.ml"
  "lib/keeper/keeper_agent_result.ml"
  "lib/keeper/keeper_agent_run.ml"
  "lib/keeper/keeper_exec_status.ml"
  "lib/keeper/keeper_generation_lineage.ml"
  "lib/keeper/keeper_hooks_oas.ml"
  "lib/keeper/keeper_hooks_oas_types.ml"
  "lib/keeper/keeper_oas_checkpoint.ml"
  "lib/keeper/keeper_rollover.ml"
  "lib/keeper/keeper_runtime_contract.ml"
  "lib/keeper/keeper_turn_driver.ml"
  "lib/keeper/keeper_turn_driver_wrappers.ml"
  "lib/keeper/keeper_unified_metrics_support.ml"
  "lib/keeper/keeper_unified_turn.ml"
  "lib/keeper/keeper_unified_turn_success.ml"
)

# Pre-approved exemptions from PR-2 audit. Each entry is `path:line:reason`.
# These four sites carry a `"runtime"` literal that is NOT a redaction
# target (schema field name, classification list, debug format string).
# Drift (line move) makes the entry stale and must be cleaned in the
# same PR. The runtime check accepts any of the listed lines.
PREAPPROVED=(
  # Classification list — enumeration of category names, not a label.
  "lib/keeper/keeper_exec_status.ml:220"
  # Debug format string inside Printf.sprintf — internal observability
  # (real provider identity, not boundary redaction). The model field
  # above it is already routed via Boundary_redaction.
  "lib/keeper/keeper_turn_driver_wrappers.ml:95"
)

violations_tmp="$(mktemp -t rfc0132-pr3.violations.XXXXXX)"
stale_tmp="$(mktemp -t rfc0132-pr3.stale.XXXXXX)"
trap 'rm -f "$violations_tmp" "$stale_tmp"' EXIT

is_preapproved() {
  local key="$1"
  local entry
  for entry in "${PREAPPROVED[@]}"; do
    [[ "$key" == "$entry" ]] && return 0
  done
  return 1
}

scan_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  # rg with line numbers + content. Each match emits a `path:line:content` row.
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local path line content
    path="${row%%:*}"
    local rest="${row#*:}"
    line="${rest%%:*}"
    content="${rest#*:}"

    # Skip doc comments (heuristic: leading `(*` after trim).
    local trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == "(*"* ]] && continue

    # Same-line pragma exemption.
    if [[ "$content" == *"RFC-0132-EXEMPT"* ]]; then
      continue
    fi

    # Preceding-line pragma exemption.
    local prev_line
    prev_line=$((line - 1))
    if [[ "$prev_line" -ge 1 ]]; then
      local prev_content
      prev_content="$(sed -n "${prev_line}p" "$path" 2>/dev/null || true)"
      if [[ "$prev_content" == *"RFC-0132-EXEMPT"* ]]; then
        continue
      fi
    fi

    local key="${path}:${line}"
    if is_preapproved "$key"; then
      continue
    fi

    printf '%s:%s:%s\n' "$path" "$line" "$content" >>"$violations_tmp"
  done < <(rg --with-filename --no-heading --line-number --color=never --fixed-strings '"runtime"' "$file" 2>/dev/null || true)
}

for f in "${SCAN_FILES[@]}"; do
  scan_file "$f"
done

# Detect stale preapproved entries: line no longer carries `"runtime"`.
for entry in "${PREAPPROVED[@]}"; do
  path="${entry%%:*}"
  line="${entry#*:}"
  [[ -f "$path" ]] || { echo "$entry (file missing)" >>"$stale_tmp"; continue; }
  current="$(sed -n "${line}p" "$path" 2>/dev/null || true)"
  if [[ "$current" != *'"runtime"'* ]]; then
    echo "$entry" >>"$stale_tmp"
  fi
done

violations_count=0
stale_count=0
[[ -s "$violations_tmp" ]] && violations_count="$(wc -l <"$violations_tmp" | tr -d ' ')"
[[ -s "$stale_tmp" ]] && stale_count="$(wc -l <"$stale_tmp" | tr -d ' ')"

printf "%-44s %8s\n" "metric" "count"
echo "--------------------------------------------------------"
printf "%-44s %8s\n" "rfc0132_pr3_scan_files" "${#SCAN_FILES[@]}"
printf "%-44s %8s\n" "rfc0132_pr3_preapproved_entries" "${#PREAPPROVED[@]}"
printf "%-44s %8s\n" "rfc0132_pr3_violations" "$violations_count"
printf "%-44s %8s\n" "rfc0132_pr3_stale_preapproved" "$stale_count"

if [[ "$MODE" = "--print" ]]; then
  if [[ -s "$violations_tmp" ]]; then
    echo
    echo "[no-runtime-literal-outside-boundary-redaction] violations:"
    sed 's/^/  - /' "$violations_tmp"
  fi
  exit 0
fi

exit_code=0

if [[ -s "$violations_tmp" ]]; then
  echo >&2
  echo "ERROR: inline \"runtime\" literal found outside Boundary_redaction:" >&2
  sed 's/^/  /' "$violations_tmp" >&2
  echo >&2
  echo "RFC-0132 requires that \"runtime\" public-surface labels go through" >&2
  echo "the Boundary_redaction SSOT module. Replace with:" >&2
  echo "  Boundary_redaction.runtime_provider_label |> Boundary_redaction.to_string" >&2
  echo "  Boundary_redaction.runtime_model_label    |> Boundary_redaction.to_string" >&2
  echo >&2
  echo "If this is an internal observability path (real provider/model" >&2
  echo "identity, not boundary redaction), add an explicit ignore comment" >&2
  echo "on the same line or the line directly above:" >&2
  echo "  (* RFC-0132-EXEMPT: internal observability *)" >&2
  exit_code=1
fi

if [[ -s "$stale_tmp" ]]; then
  echo >&2
  echo "ERROR: stale RFC-0132 preapproved entries (line no longer carries \"runtime\"):" >&2
  sed 's/^/  - /' "$stale_tmp" >&2
  echo "Remove the entry from PREAPPROVED in $(basename "${BASH_SOURCE[0]}") in the same PR." >&2
  exit_code=1
fi

if [[ "$exit_code" -eq 0 ]]; then
  echo
  echo "[no-runtime-literal-outside-boundary-redaction] OK"
fi

exit "$exit_code"
