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
# Exempt lines are counted, not just honoured. The violation budget is zero and
# the comment above explains why it stays there, but nothing was counting the
# way around it: a line carrying cancel-guard-ok is exempt whatever it does, and
# 23 of them had accumulated with no run reporting the number. A budget makes
# the twenty-fourth a decision instead of a line nobody sees.
#
# It ratchets down, never up. Removing an exemption means lowering this, which
# is the direction the guard wants; adding one means saying so in a diff.
EXEMPTIONS=0
EXEMPTION_BUDGET=23
while IFS= read -r file; do
  echo "$file" | grep -qE "/(${NO_EIO_DIRS})/" 2>/dev/null && continue
  while IFS=: read -r lineno line; do
    start=$((lineno > 3 ? lineno - 3 : 1))
    context=$(sed -n "${start},${lineno}p" "$file")
    if sed -n "${lineno}p" "$file" | grep -q 'cancel-guard-ok'; then
      # The marker has to say why. Four lines carried it bare, and each one had
      # its reason in the comment above rather than where the next reader of the
      # line would meet it -- so the line itself asserted and nothing more. The
      # reasons are all one of two: the code is outside Eio, or it re-raises.
      # Both are short enough to write.
      if ! sed -n "${lineno}p" "$file" | grep -qE 'cancel-guard-ok:[[:space:]]*[^[:space:]*]'; then
        echo "UNEXPLAINED EXEMPTION: $file:$lineno: $line"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      EXEMPTIONS=$((EXEMPTIONS + 1))
    elif ! echo "$context" | grep -q 'Eio\.Cancel\.Cancelled'; then
      echo "VIOLATION: $file:$lineno: $line"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done < <(grep -n -E '(with\s+(_|exn)\s+->|\|\s*exception\s+_\s+->)' "$file" 2>/dev/null || true)
done < <(find "$REPO_ROOT/lib" -name '*.ml' -type f)
echo "cancel-guard exemptions: $EXEMPTIONS (budget $EXEMPTION_BUDGET)"
if [ $VIOLATIONS -gt 0 ]; then
  echo "Found $VIOLATIONS wildcard catch(es) without Eio.Cancel guard."
  exit 1
fi
if [ $EXEMPTIONS -gt $EXEMPTION_BUDGET ]; then
  echo "A new cancel-guard-ok exemption was added." >&2
  echo "  An exempt line is exempt whatever it does, so each one is a place" >&2
  echo "  Cancelled can be absorbed without this guard saying so. If the line" >&2
  echo "  really is outside Eio or re-raises, say which on the line itself and" >&2
  echo "  raise EXEMPTION_BUDGET in this script in the same diff." >&2
  exit 1
fi
if [ $EXEMPTIONS -lt $EXEMPTION_BUDGET ]; then
  echo "An exemption is gone: lower EXEMPTION_BUDGET to $EXEMPTIONS." >&2
  exit 1
fi
echo "No wildcard catch violations found."
