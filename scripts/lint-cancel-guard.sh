#!/usr/bin/env bash
# Lint: detect wildcard exception catches missing Eio.Cancel.Cancelled guard.
# Exit 0 = no violations, Exit 1 = violations found.
#
# This greps raw text, so it cannot tell a catch from a code span that spells
# one inside a comment -- writing [with _ -> ()] in prose trips it. That is on
# purpose. Blanking comments first needs an OCaml lexer here, and a lexer that
# gets a nested comment or a quote wrong stops reporting real catches: a false
# negative in the guard for a bug this repo modelled in TLA+
# (CancelledAbsorbed) and hit at runtime as an Assert_failure. Prose that has
# to name the pattern says "a bare wildcard catch"; a line that really is
# exempt carries cancel-guard-ok.
set -euo pipefail
REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
NO_EIO_DIRS="dashboard_utils|masc_log|types|response|config|tool_schemas|mcp_session|ag_ui|compression|mcp_transport_protocol"
VIOLATIONS=0
while IFS= read -r file; do
  echo "$file" | grep -qE "/(${NO_EIO_DIRS})/" 2>/dev/null && continue
  while IFS=: read -r lineno line; do
    start=$((lineno > 3 ? lineno - 3 : 1))
    context=$(sed -n "${start},${lineno}p" "$file")
    if ! echo "$context" | grep -q 'Eio\.Cancel\.Cancelled' && ! sed -n "${lineno}p" "$file" | grep -q 'cancel-guard-ok'; then
      echo "VIOLATION: $file:$lineno: $line"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done < <(grep -n -E '(with\s+(_|exn)\s+->|\|\s*exception\s+_\s+->)' "$file" 2>/dev/null || true)
done < <(find "$REPO_ROOT/lib" -name '*.ml' -type f)
if [ $VIOLATIONS -gt 0 ]; then
  echo "Found $VIOLATIONS wildcard catch(es) without Eio.Cancel guard."
  exit 1
fi
echo "No wildcard catch violations found."
