#!/usr/bin/env bash
# Shell IR structural-boundary audit.
#
# Shell IR owns parsing, typed lowering, path validation, sandbox targeting,
# and dispatch. It does not classify authorization risk or decide whether an
# external effect is allowed. That decision belongs to the Keeper leaf Gate.

set -eu

usage() {
  cat <<'USAGE'
Usage: scripts/audit-shell-ir-consumption.sh [--json | --baseline FILE]

  (no args)        Print the current structural-boundary metrics.
  --json           Print the metrics as JSON.
  --baseline FILE  Compare with FILE and fail on boundary regression.
USAGE
}

mode="text"
baseline_file=""
case "${1:-}" in
  "") mode="text" ;;
  --json) mode="json" ;;
  --baseline)
    if [[ $# -lt 2 ]]; then
      echo "error: --baseline needs FILE" >&2
      usage
      exit 2
    fi
    mode="diff"
    baseline_file="$2"
    ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unknown arg $1" >&2; usage; exit 2 ;;
esac

for command in rg perl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: $command required" >&2
    exit 2
  fi
done

strip_ocaml_comments() {
  perl -0777 -pe 's{\(\*.*?\*\)}{}gs' "$1"
}

count_code_files() {
  local pattern="$1"
  local total=0
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if strip_ocaml_comments "$file" | grep -qE "$pattern"; then
      total=$((total + 1))
    fi
  done < <(rg -l "$pattern" --type-add 'ocaml:*.{ml,mli}' -tocaml lib 2>/dev/null | rg -v '/test/' || true)
  echo "$total"
}

count_code_refs() {
  local pattern="$1"
  local total=0
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local count
    count=$(strip_ocaml_comments "$file" | grep -cE "$pattern" || true)
    total=$((total + count))
  done < <(rg -l "$pattern" --type-add 'ocaml:*.{ml,mli}' -tocaml lib 2>/dev/null | rg -v '/test/' || true)
  echo "$total"
}

list_code_files() {
  local pattern="$1"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if strip_ocaml_comments "$file" | grep -qE "$pattern"; then
      echo "$file"
    fi
  done < <(rg -l "$pattern" --type-add 'ocaml:*.{ml,mli}' -tocaml lib 2>/dev/null | rg -v '/test/' || true)
}

parse_pattern='Bash\.parse_string|Masc_exec_bash_parser\.Bash\.parse_string'
parse_callers=$(count_code_files "$parse_pattern")
parse_refs=$(count_code_refs "$parse_pattern")

allowed_parse_files=(
  "lib/exec/command_gate/shell_command_gate.ml"
  "lib/exec_policy/exec_policy.ml"
  "lib/exec_policy/exec_policy_command_syntax.ml"
)

unclassified_parse_files=()
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  classified=false
  for allowed in "${allowed_parse_files[@]}"; do
    if [[ "$file" == "$allowed" ]]; then
      classified=true
      break
    fi
  done
  if [[ "$classified" == false ]]; then
    unclassified_parse_files+=("$file")
  fi
done < <(list_code_files "$parse_pattern" | sort)

dispatcher_consumers=$(list_code_files 'Keeper_tool_execute_shell_ir\.dispatch' \
  | rg '^lib/keeper/' \
  | wc -l \
  | tr -d ' ')
path_validation_surfaces=$(list_code_files 'Exec_policy\.validate_shell_ir_paths|Keeper_tool_execute_shell_ir\.(dispatch|validate_paths)' \
  | rg -v 'exec_policy/exec_policy\.(ml|mli)$' \
  | wc -l \
  | tr -d ' ')

if [[ -f specs/shell-ir-first-class/ShellIRFirstClass.tla ]]; then
  tla_spec_exists=1
else
  tla_spec_exists=0
fi

shell_word_values_refs=$(count_code_refs 'shell_word_values')
bash_words_stages_refs=$(count_code_refs 'Bash_words\.stages')
parallel_parser_refs=$((shell_word_values_refs + bash_words_stages_refs))

retired_authority_pattern='hard_forbidden|auto_approval_hard_forbidden|risk_of_typed|Shell_ir_risk|dispatch_decided|requires_operator_authorization|requires_separate_human_grant|risk_floor|max_risk|Destructive_protected|R0_Read|R1_Reversible|R2_Irreversible|Keeper_effect_request|Governance_pipeline|Operator_approval|Typed_capabilities|verify_static_safe_ir|decision_layer_level|MASC_DECISION_LAYER_LEVEL'
retired_authority_refs=$(count_code_refs "$retired_authority_pattern")

emit_json() {
  local allowed_json=""
  for file in "${allowed_parse_files[@]}"; do
    [[ -n "$allowed_json" ]] && allowed_json="${allowed_json},"
    allowed_json="${allowed_json}\"${file}\""
  done
  cat <<JSON
{
  "schema": "shell-ir-structural-boundary/v2",
  "generated_at_unix": $(date +%s),
  "parse_string_caller_files_nontest": ${parse_callers},
  "parse_string_total_refs_nontest": ${parse_refs},
  "dispatcher_adopting_keeper_files": ${dispatcher_consumers},
  "path_validation_surfaces_nontest": ${path_validation_surfaces},
  "tla_spec_exists": ${tla_spec_exists},
  "parallel_parser_refs": ${parallel_parser_refs},
  "retired_authority_refs": ${retired_authority_refs},
  "allowed_parse_string_files": [${allowed_json}]
}
JSON
}

emit_text() {
  cat <<TEXT
Shell IR Structural Boundary Audit
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

  parse_string callers:       ${parse_callers} files / ${parse_refs} refs
  Keeper dispatcher users:    ${dispatcher_consumers} files
  path validation surfaces:   ${path_validation_surfaces} files
  TLA structural spec:        ${tla_spec_exists}
  parallel parser refs:       ${parallel_parser_refs}
  retired authority refs:     ${retired_authority_refs}
TEXT
}

diff_against_baseline() {
  if [[ ! -f "$baseline_file" ]]; then
    echo "error: baseline file not found: $baseline_file" >&2
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq required for --baseline" >&2
    exit 2
  fi

  local current_json regressions=0
  current_json=$(emit_json)

  local baseline_parse baseline_parallel
  baseline_parse=$(jq -r '.parse_string_caller_files_nontest' "$baseline_file")
  baseline_parallel=$(jq -r '.parallel_parser_refs' "$baseline_file")

  if [[ "$parse_callers" -gt "$baseline_parse" ]]; then
    echo "REGRESS parse_string callers: ${baseline_parse} -> ${parse_callers}"
    regressions=$((regressions + 1))
  fi
  if [[ "$parallel_parser_refs" -gt "$baseline_parallel" ]]; then
    echo "REGRESS parallel parser refs: ${baseline_parallel} -> ${parallel_parser_refs}"
    regressions=$((regressions + 1))
  fi
  if [[ "$dispatcher_consumers" -lt 2 ]]; then
    echo "REGRESS Keeper dispatcher consumers: ${dispatcher_consumers} < 2"
    regressions=$((regressions + 1))
  fi
  if [[ "$path_validation_surfaces" -lt 4 ]]; then
    echo "REGRESS path validation surfaces: ${path_validation_surfaces} < 4"
    regressions=$((regressions + 1))
  fi
  if [[ "$tla_spec_exists" -ne 1 ]]; then
    echo "REGRESS Shell IR structural TLA spec is missing"
    regressions=$((regressions + 1))
  fi
  if [[ "$retired_authority_refs" -ne 0 ]]; then
    echo "REGRESS retired Shell IR authorization authority returned: ${retired_authority_refs} refs"
    regressions=$((regressions + 1))
  fi
  if [[ ${#unclassified_parse_files[@]} -gt 0 ]]; then
    echo "UNCLASSIFIED parse_string caller files:"
    printf '  - %s\n' "${unclassified_parse_files[@]}"
    regressions=$((regressions + 1))
  fi

  if [[ "$regressions" -gt 0 ]]; then
    echo "Shell IR structural boundary regressed in ${regressions} check(s)" >&2
    exit 1
  fi
  echo "OK (Shell IR remains structural; authorization taxonomy absent)"
}

case "$mode" in
  text) emit_text ;;
  json) emit_json ;;
  diff) diff_against_baseline ;;
esac
