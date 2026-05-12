#!/usr/bin/env bash
# lint-no-inline-error-envelope — block inline `("status", `String "error")`
# in lib/. Mirrors no-inline-ok-envelope. Use Tool_args.error_response /
# error_response_with / error_assoc / error_result instead.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ALLOWLIST=(
  # SSOT definition — canonical helpers themselves.
  "lib/tool_args.ml"

  # T27 alias backstop (sibling-include cascade for tool_local_runtime_*.ml).
  "lib/tool_local_runtime_core.ml"

  # ---- Temporary allowlist — REMOVE after T27 (#14876) merges ----
  # T27 deletes these inline json_error helpers in tool_misc_web_search,
  # tool_misc_web_fetch, and inlines the envelope in tool_operator.
  "lib/tool_misc_web_fetch.ml"
  "lib/tool_misc_web_search.ml"
  "lib/tool_operator.ml"
)

count=0
matches_file="$(mktemp)"
errors_file="$(mktemp)"
cleanup() {
  rm -f "$matches_file" "$errors_file"
}
trap cleanup EXIT

rg_status=0
rg -nP '"status",\s*`String\s+"error"' lib/ -g '*.ml' >"$matches_file" 2>"$errors_file" || rg_status=$?
if [[ $rg_status -gt 1 ]]; then
  echo "ERROR: ripgrep failed while scanning error-envelope literals" >&2
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

  if [[ "$file" == *.mli ]]; then
    continue
  fi

  echo "ERROR: inline error-envelope literal (use Tool_args.error_response / error_response_with / error_assoc / error_result): $match"
  count=$((count + 1))
done < "$matches_file"

if [[ $count -gt 0 ]]; then
  echo ""
  echo "Found $count inline error-envelope literal(s) outside the allowlist."
  echo "Migration guide:"
  echo "  - Returns string (msg only)?  Tool_args.error_response msg"
  echo "  - Returns string (+ fields)?  Tool_args.error_response_with fields"
  echo "  - Returns Yojson.Safe.t?      Tool_args.error_assoc fields"
  echo "  - Returns Tool_result.t?      Tool_args.error_result ~tool_name ~start_time msg"
  exit 1
fi

echo "OK: no inline error-envelope literals found outside allowlist"
exit 0
