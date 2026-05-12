#!/usr/bin/env bash
# no-inline-ok-envelope.sh — Block inline `("status", `String "ok")` literals
# in lib/. Use Tool_args.ok_response / ok_assoc / ok_result instead.
#
# Rationale: T27/T28/T29 consolidated 11+ inline ok-envelope sites into
# Tool_args SSOT helpers. Without a lint guard, the inline pattern
# leaks back in — AI agents learn from codebase statistics, and a few
# remaining intentional sites can be misread as license to add more.
#
# Allowlisted files fall into three categories:
#   1. SSOT definition itself (tool_args.ml).
#   2. T27 alias backstop for sibling-include cascade
#      (tool_local_runtime_core.ml).
#   3. Tier B/C intentional inline sites where wire format reordering
#      would break external consumers. Adding to this list requires a
#      one-line rationale comment in the allowlist.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ALLOWLIST=(
  # SSOT definition — the canonical helper itself.
  "lib/tool_args.ml"

  # T27 alias backstop. sibling tool_local_runtime_*.ml modules
  # consume `json_ok` / `json_error` via `include Tool_local_runtime_core`;
  # the symbols are kept as aliases for `Tool_args.ok_response` /
  # `error_response`. Direct migration of every caller is deferred.
  "lib/tool_local_runtime_core.ml"

  # Tier B: status field intentionally placed at non-zero position.
  # Helper migration would reorder JSON keys → wire-breaking for the
  # dashboard frontend that parses generated_at/cached/stale before
  # status.
  "lib/dashboard/dashboard_mission_briefing.ml"

  # Tier B: Yojson.Safe.pretty_to_string (multi-line indented form)
  # rather than to_string. The SSOT helper emits compact form. Wire
  # format divergence: a follow-up RFC must decide whether to keep
  # pretty form or normalize.
  "lib/tool_keeper.ml"

  # Single-shot health endpoint, no caller chain. De-prioritized — safe
  # to migrate but no test/wire impact.
  "lib/http_server_eio.ml"

  # ---- Temporary allowlist entries — REMOVE after T27 (#14876) merges ----
  # T27 deletes these inline json_ok helpers in tool_misc_web_search and
  # tool_misc_web_fetch (consolidating to Tool_args.ok_response). This
  # PR was opened in parallel with T27; once T27 lands these two lines
  # disappear from origin/main and the entries below must be deleted.
  "lib/tool_misc_web_fetch.ml"
  "lib/tool_misc_web_search.ml"
)

count=0
matches_file="$(mktemp)"
errors_file="$(mktemp)"
cleanup() {
  rm -f "$matches_file" "$errors_file"
}
trap cleanup EXIT

rg_status=0
rg -nP '\("status",\s*`String\s+"ok"\)' lib/ -g '*.ml' >"$matches_file" 2>"$errors_file" || rg_status=$?
if [[ $rg_status -gt 1 ]]; then
  echo "ERROR: ripgrep failed while scanning ok-envelope literals" >&2
  cat "$errors_file" >&2
  exit "$rg_status"
fi

while IFS= read -r match; do
  file=${match%%:*}

  skip=0
  for allowed in "${ALLOWLIST[@]}"; do
    if [[ "$file" == "$allowed" ]]; then
      skip=1
      break
    fi
  done
  [[ $skip -eq 1 ]] && continue

  # Skip .mli (interface signatures may quote the pattern in docstrings).
  if [[ "$file" == *.mli ]]; then
    continue
  fi

  # Strip the line:linenumber prefix for display.
  echo "ERROR: inline ok-envelope literal (use Tool_args.ok_response / ok_assoc / ok_result): $match"
  count=$((count + 1))
done < "$matches_file"

if [[ $count -gt 0 ]]; then
  echo ""
  echo "Found $count inline ok-envelope literal(s) outside the allowlist."
  echo "Migration guide:"
  echo "  - Returns string?         Tool_args.ok_response fields"
  echo "  - Returns Yojson.Safe.t?  Tool_args.ok_assoc fields"
  echo "  - Returns Tool_result.t?  Tool_args.ok_result ~tool_name ~start_time fields"
  echo ""
  echo "If the site genuinely requires non-zero status position or pretty"
  echo "serialization, add a one-line rationale to ALLOWLIST in this script."
  exit 1
fi

echo "OK: no inline ok-envelope literals found outside allowlist"
exit 0
