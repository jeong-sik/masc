#!/usr/bin/env bash
# Shell legacy purge ratchet.
#
# The Shell IR Phase 5 cleanup target is to remove the remaining legacy
# string-tokenizer/path-scanner markers from lib/, test/, and keeper prompts. This guard
# freezes the current debt while deletion PRs drive the baselines down to 0.
#
# Usage:
#   bash scripts/lint/shell-legacy-purge-ratchet.sh
#   bash scripts/lint/shell-legacy-purge-ratchet.sh --print
#   bash scripts/lint/shell-legacy-purge-ratchet.sh --regenerate

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COUNT_BASELINE="${ROOT}/scripts/lint/shell-legacy-purge-ratchet.baseline"
FILE_BASELINE="${ROOT}/scripts/lint/shell-legacy-purge-ratchet.files"
NEEDLES=(
  "tokenize_path_args"
  "path_validation_tokens"
  "forbidden_shell_chars"
  "raw_keeper_bash_shape_block"
  "has_coding_shell_injection_metachar"
  "has_process_substitution"
  "has_unsafe_redirection"
  "has_dangerous_ampersand"
  "split_shell_tokens"
  "is_safe_fd_redirect_token"
  "invokes_direct_dune"
  "extract_command_name"
  "Shell_ir_validator"
  "typed_advisor"
  "MASC_BASH_TYPED"
  "shell_ir_shape_scan_text"
  "shell_ir_parse_failure_shape_block"
  "has_malformed_dev_null_redirect_token"
  "shell_word_simple_commands"
  "command_has_repo_wide_scan"
  "Keeper_shell_bash_words"
  "keeper_shell_bash_words"
  "lowercase_shell_words"
  "String.split_on_char ' ' cmd"
  "String.split_on_char ' ' config.command"
  "shell_words_prefix"
  "shell_words_with_boundaries"
  "Masc_exec.Command_words"
  "Command_words.stages"
  "include Masc_exec.Command_words"
  "strip_command_wrappers"
  "cmd_gh_pr_native_subcommand"
  "cmd_contains_gh_pr_create"
  "find_unquoted_logic_op"
  "split_unquoted_single_pipeline"
  "literal_head_limit_is_safe"
  "strip_trailing_dev_null_redirect"
  "literal_echo_is_safe"
  "safe_cd_read_fallback"
  "safe_read_head_pipeline"
  "safe_read_or_echo_fallback"
  "gate_diff_shadow"
  "MASC_BASH_AST_SHADOW_LOG"
  "MASC_BASH_AST_ONLY"
  "diff_command"
  "legacy_verdict"
  "shadow_verdict"
  "shadow_parse_outcome"
  "incr_gate_diff"
  "incr_too_complex"
  "disagree_ratio"
  "shadow_parse_coverage"
  "Legacy_v0"
  "Typed_v1"
  "MASC_KEEPER_BASH_DESCRIPTOR_VARIANT"
  "keeper_bash_cmd_field"
  "coding_keeper_bridge_tools_for_variant"
  "Keeper_shell_bash_redirects"
  "Keeper_shell_bash_simple_commands"
  "Keeper_shell_bash_command_intent"
  "Keeper_shell_bash_task_probe"
  "Keeper_shell_bash_task_state"
  "Keeper_shell_bash_shape_messages"
  "Keeper_shell_bash_shape_ir"
  "Keeper_shell_bash_native_tool_hint"
  "Keeper_shell_bash_repo_wide_scan"
  "keeper_shell_bash_redirects"
  "keeper_shell_bash_simple_commands"
  "keeper_shell_bash_command_intent"
  "keeper_shell_bash_task_probe"
  "keeper_shell_bash_task_state"
  "keeper_shell_bash_shape_messages"
  "keeper_shell_bash_shape_ir"
  "keeper_shell_bash_native_tool_hint"
  "keeper_shell_bash_repo_wide_scan"
  "keeper_bash_output"
  "keeper_bash_kill"
  "run_in_background"
  "background_task_id"
  "MASC_BASH_AUTO_BG"
  "MASC_BLOCKING_BUDGET_MS"
  "auto_bg"
  "Exec_run"
  "exec_run"
  "Bash { command"
  "Bash command="
  "Bash command='"
  "Path syntax blocked"
  "Path_syntax_blocked"
  "path_syntax_blocked"
  "Worker_dev_tools_path_words"
  "worker_dev_tools_path_words"
  "Path_words"
  "path_token_error_hint"
  "path_syntax_blocked_message"
)
SCOPE=(lib test config/prompts)

for tool in awk comm mktemp rg sed sort tr wc; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[shell-legacy-purge-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

current_count() {
  local needle="$1"
  (
    set +o pipefail
    cd "$ROOT"
    rg --fixed-strings -n "$needle" "${SCOPE[@]}" 2>/dev/null \
      | wc -l \
      | tr -d ' '
  )
}

baseline_count() {
  local needle="$1"
  awk -v needle="$needle" '
    $0 ~ /^[[:space:]]*#/ || NF == 0 { next }
    $1 == needle { print $2; found = 1 }
    END { if (!found) print 0 }
  ' "$COUNT_BASELINE"
}

current_files() {
  local needle="$1"
  (
    set +o pipefail
    cd "$ROOT"
    rg --fixed-strings -l "$needle" "${SCOPE[@]}" 2>/dev/null \
      | sort -u
  )
}

baseline_files() {
  local needle="$1"
  awk -v needle="$needle" '
    $0 ~ /^[[:space:]]*#/ || NF == 0 { next }
    $1 == needle { print $2 }
  ' "$FILE_BASELINE" | sort -u
}

print_counts() {
  printf "%-34s %9s  %9s\n" "needle" "current" "baseline"
  echo "--------------------------------------------------------"
  local needle
  for needle in "${NEEDLES[@]}"; do
    printf "%-34s %9s  %9s\n" \
      "$needle" \
      "$(current_count "$needle")" \
      "$(baseline_count "$needle")"
  done
}

regenerate() {
  {
    echo "# Shell legacy purge ratchet baseline."
    echo "#"
    echo "# Format: <needle> <max-hit-count>"
    echo "# Scope: lib/, test/, and config/prompts/"
    echo "# The long-term target for every row is 0. Cleanup PRs may lower these"
    echo "# counts; no PR may raise them."
    local needle
    for needle in "${NEEDLES[@]}"; do
      printf "%s %s\n" "$needle" "$(current_count "$needle")"
    done
  } >"$COUNT_BASELINE"

  {
    echo "# Shell legacy purge ratchet file baseline."
    echo "#"
    echo "# Format: <needle> <repo-relative-path>"
    echo "# New files may not gain these legacy markers. Deletion PRs should remove"
    echo "# rows as they remove the corresponding markers."
    local needle path
    for needle in "${NEEDLES[@]}"; do
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf "%s %s\n" "$needle" "$path"
      done < <(current_files "$needle")
    done
  } >"$FILE_BASELINE"

  echo "[shell-legacy-purge-ratchet] regenerated baselines"
}

check() {
  local needle current baseline current_tmp baseline_tmp new_tmp drift=0
  current_tmp="$(mktemp -t shell-legacy-current.XXXXXX)"
  baseline_tmp="$(mktemp -t shell-legacy-baseline.XXXXXX)"
  new_tmp="$(mktemp -t shell-legacy-new.XXXXXX)"
  trap 'rm -f "$current_tmp" "$baseline_tmp" "$new_tmp"' RETURN

  for needle in "${NEEDLES[@]}"; do
    current="$(current_count "$needle")"
    baseline="$(baseline_count "$needle")"
    if (( current > baseline )); then
      echo "[shell-legacy-purge-ratchet] DRIFT UP: ${needle} current=${current} baseline=${baseline}" >&2
      echo "  remove the new legacy marker or lower the existing debt first." >&2
      drift=1
    elif (( current < baseline )); then
      echo "[shell-legacy-purge-ratchet] SHRANK: ${needle} current=${current} baseline=${baseline}"
      echo "  update scripts/lint/shell-legacy-purge-ratchet.baseline in the cleanup PR."
    fi

    current_files "$needle" >"$current_tmp"
    baseline_files "$needle" >"$baseline_tmp"
    comm -13 "$baseline_tmp" "$current_tmp" >"$new_tmp"
    if [[ -s "$new_tmp" ]]; then
      echo "[shell-legacy-purge-ratchet] DRIFT UP: new files contain ${needle}" >&2
      sed 's/^/  - /' "$new_tmp" >&2
      echo "  do not move or expand legacy shell tokenizer/path-scanner code." >&2
      drift=1
    fi
  done

  return "$drift"
}

case "${1:-}" in
  --print)
    print_counts
    ;;
  --regenerate)
    regenerate
    ;;
  "")
    print_counts
    if check; then
      echo
      echo "[shell-legacy-purge-ratchet] OK"
      exit 0
    else
      echo
      echo "[shell-legacy-purge-ratchet] FAIL - current exceeds baseline" >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--print|--regenerate]" >&2
    exit 1
    ;;
esac
