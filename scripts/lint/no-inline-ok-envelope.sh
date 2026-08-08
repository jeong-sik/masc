#!/usr/bin/env bash
# no-inline-ok-envelope.sh — Block inline `("status", `String "ok")` literals
# in lib/. Use Tool_args.ok_response / ok_assoc or Tool_result.make_ok instead.
#
# The allowlist contains the SSOT definition and one ordered wire producer.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ALLOWLIST=(
  # Canonical helper definition.
  "lib/tool_types/tool_args.ml"

  # The briefing contract emits cache provenance before status.
  "lib/dashboard/dashboard_briefing_sections.ml"
)

count=0
matches_file="$(mktemp)"
errors_file="$(mktemp)"
cleanup() {
  rm -f "$matches_file" "$errors_file"
}
trap cleanup EXIT

scan_status=0
if command -v rg >/dev/null 2>&1; then
  rg -nP '\("status",\s*`String\s+"ok"\)' lib/ -g '*.ml' >"$matches_file" 2>"$errors_file" || scan_status=$?
  if [[ $scan_status -gt 1 ]]; then
    echo "ERROR: ripgrep failed while scanning ok-envelope literals" >&2
    cat "$errors_file" >&2
    exit "$scan_status"
  fi
else
  grep -RInE --include='*.ml' '\("status",[[:space:]]*`String[[:space:]]+"ok"\)' lib/ >"$matches_file" 2>"$errors_file" || scan_status=$?
  if [[ $scan_status -gt 1 ]]; then
    echo "ERROR: grep failed while scanning ok-envelope literals" >&2
    cat "$errors_file" >&2
    exit "$scan_status"
  fi
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
  echo "ERROR: inline ok-envelope literal (use Tool_args.ok_response / ok_assoc): $match"
  count=$((count + 1))
done < "$matches_file"

if [[ $count -gt 0 ]]; then
  echo ""
  echo "Found $count inline ok-envelope literal(s) outside the allowlist."
  echo "Canonical constructors:"
  echo "  - Returns string?         Tool_args.ok_response fields"
  echo "  - Returns Yojson.Safe.t?  Tool_args.ok_assoc fields"
  echo "  - Returns Tool_result.result? Tool_result.make_ok ~data:(Tool_args.ok_assoc fields)"
  echo ""
  echo "If the site genuinely requires non-zero status position or pretty"
  echo "serialization, add a one-line rationale to ALLOWLIST in this script."
  exit 1
fi

echo "OK: no inline ok-envelope literals found outside allowlist"
exit 0
