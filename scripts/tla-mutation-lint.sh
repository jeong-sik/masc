#!/usr/bin/env bash
# Detect ref-state and Atomic.set mutations in lib/keeper/.
#
# This is the detect-only first cut of the ppx_tla_lint track from
# the Kimi keeper FSM audit (2026-04-28). Surfaces every mutation
# site so the ratchet (scripts/tla-mutation-lint-ratchet.sh) can
# enforce monotonic decrease as the team migrates each site to:
#   (a) a derived state (no mutation), or
#   (b) marked with a (* tla-lint: allow-mutation: <reason> *) line
#       comment immediately above, justifying why this site is a
#       genuine non-FSM mutation (metric counter, fiber signal, etc.).
#
# Patterns scanned (lib/keeper/ only):
#   1. Pexp_apply  Atomic.set X v
#   2. Pexp_setfield (record-field assign)         X.f <- v   /   X.f := v
#   3. Pexp_apply  ( := ) for ref cells           X := v
#
# Escape: a line whose previous non-blank source line contains the
# tag [tla-lint: allow-mutation:] is excluded from the count. Example:
#
#   (* tla-lint: allow-mutation: heartbeat counter, not FSM state *)
#   Atomic.set tick_count (n + 1)
#
# The intent is to make the audit budget visible: every unmasked
# mutation in lib/keeper/ is potentially a TLA+ Next-set drift
# candidate. Future PR (Track 1B) promotes the ratchet to zero and
# flips this lint to a hard build error via PPX integration.
#
# Usage:
#   scripts/tla-mutation-lint.sh              # print one VIOLATION line per match, count to stderr
#   scripts/tla-mutation-lint.sh --count      # print the total count only, on stdout
#
# Exit code: 0 always (this is the detector — the ratchet decides
# pass/fail).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Override target dir via env var (used by tests). Default scans the
# real lib/keeper/ relative to the script's repo.
KEEPER_DIR="${TLA_LINT_KEEPER_DIR:-${REPO_ROOT}/lib/keeper}"

for tool in rg sed awk wc; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[tla-mutation-lint] required tool missing: $tool" >&2
    exit 1
  }
done

MODE="report"
if [ "${1:-}" = "--count" ]; then
  MODE="count"
fi

# Combined pattern. We use rg with -n for line numbers and -e for
# multiple expressions. The regex intentionally matches the OCaml
# surface, not the AST — false positives are filtered by the
# escape-marker check below.
PATTERNS=(
  -e '\bAtomic\.set\b'
  -e '<\-'                    # record field set: x.f <- v
  -e ' := '                   # ref cell set:   x := v
)

VIOLATIONS=0
TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

# Scan lib/keeper/ recursively. Skip .mli (declarations only,
# no mutations). Skip generated files under _build/.
rg --no-heading --line-number --type ocaml "${PATTERNS[@]}" \
   "$KEEPER_DIR" \
   --glob '!*.mli' \
   --glob '!_build/**' \
   2>/dev/null > "$TMPFILE" || true

while IFS=: read -r file lineno line; do
  [ -z "$file" ] && continue

  # Strip leading whitespace from the matched line for false-positive
  # filtering. We exclude:
  #   - String literals containing := (rare but real: e.g. error
  #     messages like "use := not =")
  #   - Comment-only lines (* X := Y *)  — pure prose
  trimmed="$(echo "$line" | sed -E 's/^[[:space:]]+//')"
  case "$trimmed" in
    '*'*|'(*'*|'//'*) continue ;;  # comment line
  esac

  # Look at the previous non-blank line for the allow-mutation tag.
  start=$((lineno > 5 ? lineno - 5 : 1))
  end=$((lineno - 1))
  if [ "$end" -ge "$start" ]; then
    prev_context="$(sed -n "${start},${end}p" "$file" 2>/dev/null || true)"
    if echo "$prev_context" | grep -q 'tla-lint:[[:space:]]*allow-mutation:'; then
      continue
    fi
  fi

  VIOLATIONS=$((VIOLATIONS + 1))
  if [ "$MODE" = "report" ]; then
    # Strip leading repo root for compact display, falling back to absolute.
    rel="${file#$REPO_ROOT/}"
    [ "$rel" = "$file" ] && rel="${file#$KEEPER_DIR/}"
    echo "VIOLATION: ${rel}:${lineno}: ${trimmed}"
  fi
done < "$TMPFILE"

if [ "$MODE" = "count" ]; then
  echo "$VIOLATIONS"
else
  echo "[tla-mutation-lint] mutation sites in lib/keeper/: $VIOLATIONS" >&2
fi
exit 0
