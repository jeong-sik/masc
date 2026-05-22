#!/usr/bin/env bash
# Shell IR consumption audit — RFC-0156 baseline metric collector.
#
# Motivation: RFC-0156 (Shell IR 1급 승격) promotes Shell IR from
# transit-only envelope to single-source decision substrate.
# Plan SSOT: ~/me/memory/shell-ir-first-class-promotion-todo-2026-05-23.html
#
# G1-G7 KPIs measured:
#   G1  Bash.parse_string caller count (lib/, non-test)
#   G2  is_write_operation / is_destructive_bash_operation signature
#       (string vs Shell_ir.t) — heuristic via grep
#   G3  gh op gate_typed routing (heuristic — counts gate_typed callers
#       in keeper_shell_ops.ml and keeper handlers)
#   G4  Risk-stamped IR (existence of Shell_ir.simple.risk or
#       'decided phantom envelope)
#   G5  validate_shell_ir_paths caller count (target: 4 keeper ops)
#   G6  spec/ShellIRFirstClass.tla existence
#   G7  shell_word_values + Bash_words.stages parallel-parser callers
#
# Output modes:
#   default      Human-readable metric table.
#   --json       baseline.json suitable for ratchet diff.
#   --baseline F Diff current metrics against baseline F; exit 1 if any
#                G* regresses (used by CI ratchet, S7).
#
# Run from masc-mcp repo root.

set -eu
# Intentionally no pipefail: `rg -c` exits 1 when zero matches, and we
# want those to fall through awk as "0", not abort the whole audit.

usage() {
  cat <<'USAGE'
Usage: scripts/audit-shell-ir-consumption.sh [--json | --baseline FILE]

  (no args)        Print metric table to stdout.
  --json           Print JSON object to stdout (baseline format).
  --baseline FILE  Diff current vs FILE; exit 1 on regression.
USAGE
}

mode="text"
baseline_file=""
case "${1:-}" in
  "") mode="text" ;;
  --json) mode="json" ;;
  --baseline)
    if [[ $# -lt 2 ]]; then echo "error: --baseline needs FILE" >&2; usage; exit 2; fi
    mode="diff"; baseline_file="$2" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unknown arg $1" >&2; usage; exit 2 ;;
esac

if ! command -v rg >/dev/null 2>&1; then
  echo "error: rg (ripgrep) required" >&2
  exit 2
fi

# ---- G1: Bash.parse_string callers (lib/, non-test) ----
g1_callers_lib=$(rg -l 'Bash\.parse_string|Masc_exec_bash_parser\.Bash\.parse_string' lib/ 2>/dev/null \
  | rg -v '/test/' \
  | wc -l | tr -d ' ')
g1_total_refs=$(rg -c 'Bash\.parse_string|Masc_exec_bash_parser\.Bash\.parse_string' lib/ 2>/dev/null \
  | rg -v '/test/' \
  | awk -F: '{s+=$2} END{print s+0}')

# ---- G2: classifier signature ----
# Heuristic: scan let signatures of is_write_operation / is_destructive_bash_operation
g2_string_sig=$(rg -c '^let is_(write_operation|destructive_bash_operation) [a-z]+ ?=' lib/exec_policy_mutation_classifier.ml 2>/dev/null || echo 0)
g2_ir_sig=$(rg -c '^let is_(write_operation|destructive_bash_operation) \(.*: Shell_ir' lib/exec_policy_mutation_classifier.ml 2>/dev/null || echo 0)

# ---- G3: gate_typed routing in keeper handlers ----
g3_gate_typed=$(rg -c 'Shell_(command_)?gate\.gate_typed|gate_typed ~' lib/keeper/ 2>/dev/null \
  | awk -F: '{s+=$2} END{print s+0}')

# ---- G4: risk stamp existence ----
g4_risk_in_simple=$(rg -c 'risk\s*:\s*risk_class|type.*risk_class' lib/exec/shell_ir.ml lib/exec/shell_ir.mli 2>/dev/null \
  | awk -F: '{s+=$2} END{print s+0}')
g4_phantom=$(rg -c "'decided\b|decided_ir" lib/exec/shell_ir.ml lib/exec/shell_ir.mli 2>/dev/null \
  | awk -F: '{s+=$2} END{print s+0}')

# ---- G5: validate_shell_ir_paths callers ----
g5_callers=$(rg -l 'validate_shell_ir_paths' lib/ 2>/dev/null \
  | rg -v '/test/' \
  | rg -v 'exec_policy\.ml$|exec_policy\.mli$' \
  | wc -l | tr -d ' ')

# ---- G6: TLA+ spec ----
if [[ -f spec/ShellIRFirstClass.tla ]]; then g6_spec=1; else g6_spec=0; fi

# ---- G7: parallel parser refs ----
g7_shell_word_values=$(rg -c 'shell_word_values' lib/ 2>/dev/null \
  | rg -v '/test/' \
  | awk -F: '{s+=$2} END{print s+0}')
g7_bash_words_stages=$(rg -c 'Bash_words\.stages' lib/ 2>/dev/null \
  | rg -v '/test/' \
  | awk -F: '{s+=$2} END{print s+0}')
g7_total=$(( g7_shell_word_values + g7_bash_words_stages ))

# ---- IR constructor count (Simple / Pipeline) — non-G but informative ----
ir_constructors=$(rg -c 'Shell_ir\.Simple|Shell_ir\.Pipeline' lib/ 2>/dev/null \
  | rg -v '/test/' \
  | awk -F: '{s+=$2} END{print s+0}')

emit_json() {
  cat <<JSON
{
  "schema": "shell-ir-consumption/v1",
  "generated_at_unix": $(date +%s),
  "g1_parse_string_caller_files_nontest": ${g1_callers_lib},
  "g1_parse_string_total_refs_nontest": ${g1_total_refs},
  "g2_classifier_string_sig": ${g2_string_sig},
  "g2_classifier_ir_sig": ${g2_ir_sig},
  "g3_gate_typed_refs_in_keeper": ${g3_gate_typed},
  "g4_risk_in_simple": ${g4_risk_in_simple},
  "g4_phantom_envelope": ${g4_phantom},
  "g5_validate_paths_callers_nontest": ${g5_callers},
  "g6_tla_spec_exists": ${g6_spec},
  "g7_shell_word_values_refs": ${g7_shell_word_values},
  "g7_bash_words_stages_refs": ${g7_bash_words_stages},
  "g7_parallel_parser_total": ${g7_total},
  "info_ir_constructors_nontest": ${ir_constructors}
}
JSON
}

emit_text() {
  cat <<TEXT
Shell IR Consumption Audit — RFC-0156 baseline
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

  G1  Bash.parse_string callers (lib/, non-test files)
        ${g1_callers_lib} files / ${g1_total_refs} refs       (target: ≤ 3 files)

  G2  Mutation classifier signature
        string sig: ${g2_string_sig}, IR sig: ${g2_ir_sig}
                                                       (target: string=0, IR≥2)

  G3  Shell_command_gate.gate_typed refs in lib/keeper/
        ${g3_gate_typed} refs                          (target: ≥ 4 keeper ops covered)

  G4  Risk-stamped IR
        risk in simple: ${g4_risk_in_simple}, phantom: ${g4_phantom}
                                                       (target: one of these ≥ 1)

  G5  validate_shell_ir_paths caller files (non-test, non-defining)
        ${g5_callers} files                            (target: ≥ 4)

  G6  TLA+ spec spec/ShellIRFirstClass.tla
        exists: ${g6_spec}                             (target: 1)

  G7  Parallel parser refs (shell_word_values + Bash_words.stages, non-test)
        shell_word_values: ${g7_shell_word_values}, Bash_words.stages: ${g7_bash_words_stages}
        total: ${g7_total}                             (target: 0)

  info  Shell_ir.(Simple|Pipeline) constructor refs (non-test)
        ${ir_constructors}
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
  local current_json
  current_json=$(emit_json)
  local regressions=0
  # G1 must not increase
  local b_g1 c_g1
  b_g1=$(jq -r '.g1_parse_string_caller_files_nontest' "$baseline_file")
  c_g1=$(echo "$current_json" | jq -r '.g1_parse_string_caller_files_nontest')
  if [[ "$c_g1" -gt "$b_g1" ]]; then
    echo "REGRESS G1 (parse_string callers): ${b_g1} → ${c_g1}"
    regressions=$((regressions + 1))
  fi
  # G7 must not increase
  local b_g7 c_g7
  b_g7=$(jq -r '.g7_parallel_parser_total' "$baseline_file")
  c_g7=$(echo "$current_json" | jq -r '.g7_parallel_parser_total')
  if [[ "$c_g7" -gt "$b_g7" ]]; then
    echo "REGRESS G7 (parallel parser refs): ${b_g7} → ${c_g7}"
    regressions=$((regressions + 1))
  fi
  if [[ "$regressions" -gt 0 ]]; then
    echo "RFC-0156 baseline regressed in ${regressions} metric(s)" >&2
    exit 1
  fi
  echo "OK (RFC-0156 ratchet: no G1/G7 regression)"
}

case "$mode" in
  text) emit_text ;;
  json) emit_json ;;
  diff) diff_against_baseline ;;
esac
