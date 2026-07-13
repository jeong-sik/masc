#!/usr/bin/env bash
# MASC domain ownership ratchet.
#
# The repository still has a mostly-flat OCaml namespace in places, so dune
# cannot yet enforce every semantic boundary. This gate freezes current debt at
# the file/rule level and fails if a leaf domain learns a new external domain
# family. Baselines may shrink; they must not grow.
#
# Boundaries covered here:
#   - Goal domain may not learn new Task state coupling. Existing files that
#     still inspect Masc_domain.task / Workspace_query are baselined debt.
#   - Leaf Tool / Turn FSM / Board types / Task state / Memory JSONL
#     modules may not learn Keeper, OAS provider/runtime, workspace-task, or
#     DB/vector persistence concepts.
#   - MASC persistence remains filesystem/JSONL; DB/vector backend terms are
#     rejected in the leaf state domains scanned here.
#
# Usage:
#   bash scripts/lint/masc-domain-boundary-ratchet.sh
#   bash scripts/lint/masc-domain-boundary-ratchet.sh --fail
#   bash scripts/lint/masc-domain-boundary-ratchet.sh --print
#   bash scripts/lint/masc-domain-boundary-ratchet.sh --regenerate

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE="${ROOT}/scripts/lint/masc-domain-boundary-ratchet.baseline"

for tool in find mktemp perl rg sed sort comm wc tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[masc-domain-boundary-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

strip_ocaml_file() {
  perl -0777 -e '
    local $/; my $s = <STDIN>;
    my @o; my $i = 0; my $n = length $s; my $depth = 0; my $str = 0;
    while ($i < $n) {
      my $c  = substr($s, $i, 1);
      my $c2 = substr($s, $i, 2);
      if (!$str && $c2 eq "(*") { $depth++; $i += 2; next; }
      if (!$str && $c2 eq "*)" && $depth > 0) { $depth--; $i += 2; next; }
      if ($depth > 0) { push @o, "\n" if $c eq "\n"; $i++; next; }
      if (!$str && $c eq chr(34)) { $str = 1; $i++; next; }
      if ($str && $c eq "\\") { $i += 2; next; }
      if ($str && $c eq chr(34)) { $str = 0; $i++; next; }
      if ($str) { push @o, "\n" if $c eq "\n"; $i++; next; }
      push @o, $c; $i++;
    }
    print join("", @o);
  ' < "$1"
}

file_has_pattern() {
  local file="$1"
  local pattern="$2"
  local stripped
  stripped="$(strip_ocaml_file "$file")"
  rg -q "$pattern" <<<"$stripped"
}

scan_files() {
  (
    cd "$ROOT"
    find "$@" -type f \( -name '*.ml' -o -name '*.mli' \) | sort -u
  )
}

emit_rule_matches() {
  local rule="$1"
  local pattern="$2"
  shift 2

  while IFS= read -r file; do
    if file_has_pattern "${ROOT}/${file}" "$pattern"; then
      printf '%s|%s\n' "$rule" "$file"
    fi
  done < <(scan_files "$@")
}

current_entries() {
  local keeper_pattern oas_provider_pattern workspace_task_pattern db_pattern
  keeper_pattern='\b(Keeper_[A-Za-z0-9_]+|Agent_tool_descriptor|Agent_tool_descriptor_resolution|Agent_tool_dispatch_runtime|Keeper_tool_alias|Keeper_types_profile|Task_keeper_backend)\b'
  oas_provider_pattern='\b(Agent_sdk|Provider_runtime_binding|Provider_kind_resolver|Provider_adapter|Masc_oas_bridge)\b|\bOas\.'
  workspace_task_pattern='\b(Workspace_query|Masc_domain\.task)\b'
  db_pattern='(?i)\b(qdrant|pgvector|postgres|postgresql|supabase|sqlite|database)\b'

  {
    emit_rule_matches "goal_to_task_state" "$workspace_task_pattern" lib/goal
    emit_rule_matches "goal_to_keeper_runtime" "$keeper_pattern" lib/goal
    emit_rule_matches "goal_to_oas_provider" "$oas_provider_pattern" lib/goal

    emit_rule_matches "tool_to_keeper_runtime" "$keeper_pattern" lib/tool
    emit_rule_matches "tool_to_workspace_task" "$workspace_task_pattern" lib/tool
    emit_rule_matches "tool_to_oas_provider" "$oas_provider_pattern" lib/tool

    emit_rule_matches "turn_fsm_to_keeper_runtime" "$keeper_pattern" lib/turn_fsm
    emit_rule_matches "turn_fsm_to_oas_provider" "$oas_provider_pattern" lib/turn_fsm
    emit_rule_matches "turn_fsm_to_workspace_task" "$workspace_task_pattern" lib/turn_fsm

    emit_rule_matches "board_types_to_keeper_runtime" "$keeper_pattern" lib/board_types
    emit_rule_matches "board_types_to_oas_provider" "$oas_provider_pattern" lib/board_types
    emit_rule_matches "board_types_to_workspace_task" "$workspace_task_pattern" lib/board_types

    emit_rule_matches "task_transition_to_keeper_runtime" "$keeper_pattern" \
      lib/types/types_core.ml lib/types/types_core.mli
    emit_rule_matches "task_transition_to_oas_provider" "$oas_provider_pattern" \
      lib/types/types_core.ml lib/types/types_core.mli

    emit_rule_matches "leaf_state_to_db_backend" "$db_pattern" \
      lib/board_types lib/goal lib/types/types_core.ml lib/types/types_core.mli
  } | sort -u
}

baseline_entries() {
  if [[ -f "$BASELINE" ]]; then
    sed -E 's/#.*//; s/[[:space:]]+$//; /^$/d' "$BASELINE" | sort -u
  fi
}

count_rule_entries() {
  local rule="$1"
  local file="$2"
  (rg -c "^${rule}\\|" "$file" 2>/dev/null || true) \
    | awk -F: '{sum+=$NF} END {print sum+0}'
}

print_counts() {
  local cur_tmp base_tmp
  cur_tmp="$(mktemp -t masc-domain-boundary.current.XXXXXX)"
  base_tmp="$(mktemp -t masc-domain-boundary.baseline.XXXXXX)"
  trap 'rm -f "$cur_tmp" "$base_tmp"' RETURN

  current_entries >"$cur_tmp"
  baseline_entries >"$base_tmp"

  printf "%-34s %9s  %9s\n" "metric" "current" "baseline"
  echo "----------------------------------------------------------"
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    local cur base
    cur="$(count_rule_entries "$rule" "$cur_tmp")"
    base="$(count_rule_entries "$rule" "$base_tmp")"
    printf "%-34s %9d  %9d\n" "$rule" "$cur" "$base"
  done < <({ cut -d'|' -f1 "$cur_tmp"; cut -d'|' -f1 "$base_tmp"; } | sort -u)

  echo
  echo "current entries:"
  sed 's/^/  - /' "$cur_tmp"
}

regenerate() {
  local tmp
  tmp="$(mktemp -t masc-domain-boundary.regen.XXXXXX)"
  trap 'rm -f "$tmp"' RETURN

  current_entries >"$tmp"
  {
    echo "# MASC domain ownership ratchet baseline."
    echo "# Format: rule|path"
    echo "# This file freezes current coupling debt. Entries may SHRINK but must NOT GROW."
    echo "# Regenerate with: bash scripts/lint/masc-domain-boundary-ratchet.sh --regenerate"
    echo "#"
    cat "$tmp"
  } >"$BASELINE"
  echo "[masc-domain-boundary-ratchet] regenerated baseline ($(baseline_entries | wc -l | tr -d ' ') entries)"
}

check() {
  local cur_tmp base_tmp new_tmp stale_tmp drift=0
  cur_tmp="$(mktemp -t masc-domain-boundary.current.XXXXXX)"
  base_tmp="$(mktemp -t masc-domain-boundary.baseline.XXXXXX)"
  new_tmp="$(mktemp -t masc-domain-boundary.new.XXXXXX)"
  stale_tmp="$(mktemp -t masc-domain-boundary.stale.XXXXXX)"
  trap 'rm -f "$cur_tmp" "$base_tmp" "$new_tmp" "$stale_tmp"' RETURN

  current_entries >"$cur_tmp"
  baseline_entries >"$base_tmp"
  comm -13 "$base_tmp" "$cur_tmp" >"$new_tmp"
  comm -23 "$base_tmp" "$cur_tmp" >"$stale_tmp"

  if [[ -s "$new_tmp" ]]; then
    echo "[masc-domain-boundary-ratchet] DRIFT UP: new domain boundary coupling:" >&2
    sed 's/^/  - /' "$new_tmp" >&2
    echo "  Keep MASC/OAS ownership and leaf domains separate. Move integration" >&2
    echo "  behaviour into a keeper/runtime/workspace adapter instead of teaching" >&2
    echo "  the leaf domain about that external family. Do not add new entries" >&2
    echo "  to the baseline." >&2
    drift=1
  fi

  if [[ -s "$stale_tmp" ]]; then
    echo "[masc-domain-boundary-ratchet] STALE BASELINE: severed coupling still listed:" >&2
    sed 's/^/  - /' "$stale_tmp" >&2
    echo "  Remove stale entries in the same PR that severed them: run --regenerate." >&2
    drift=1
  fi

  return "$drift"
}

case "${1:-}" in
  --print)
    print_counts
    ;;
  --regenerate)
    regenerate
    ;;
  ""|--fail)
    if check; then
      echo "[masc-domain-boundary-ratchet] OK ($(baseline_entries | wc -l | tr -d ' ') baselined, 0 new)."
      exit 0
    else
      echo >&2
      echo "[masc-domain-boundary-ratchet] FAIL - domain boundary grew." >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--fail|--print|--regenerate]" >&2
    exit 1
    ;;
esac
