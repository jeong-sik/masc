#!/usr/bin/env bash
# CI gate: Detect Silent Failure (SIL) anti-patterns.
# Meta-issue: #9517
#
# Anti-patterns scanned:
#   1. try/ignore wrapping calls that already return unit (hides exceptions)
#   2. match branches with wildcard that silently swallow errors
#   3. Hashtbl.find without find_opt fallback (Not_found becomes silent)
#   4. Option.get without prior is_some check (raises but is a code smell)
#
# CONTRACT: Failures must be noisy by default. Explicit opt-in (log + ignore)
# is required for every suppressed exception path.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

# 1. try/ignore on unit-returning calls (exceptions swallowed silently)
#    Exclude comments and test files where deliberate mocking is expected.
echo "=== Scan: try/ignore anti-pattern ==="
matches=$(rg -n 'try\s+ignore\s*\(' lib/ --type ml -g '!test/' || true)
if [ -n "$matches" ]; then
  echo "FAIL: try/ignore wrapping found (exceptions silently swallowed):"
  echo "$matches" | head -20
  exit_code=1
else
  echo "PASS"
fi

# 2. Wildcard match branches that return unit without logging
#    Heuristic: | _ -> () or | _ -> ignore (without preceding log line)
echo "=== Scan: wildcard -> () swallow ==="
matches=$(rg -B1 -n '\|\s*_\s*->\s*\(\)' lib/ --type ml -g '!test/' || true)
# Filter out lines that have a log/traceln on the preceding line
filtered=$(echo "$matches" | rg -v 'Log\.|traceln|log_' || true)
if [ -n "$filtered" ]; then
  echo "WARN: wildcard -> () branches without visible logging:"
  echo "$filtered" | head -20
  # Treat as warning for now; escalate to FAIL after codebase cleanup.
fi

# 3. Hashtbl.find without matching find_opt in the same function
#    This is a heuristic: we flag Hashtbl.find and require a justification
#    comment or a find_opt in the same file.
echo "=== Scan: Hashtbl.find without find_opt fallback ==="
files_with_find=$(rg -l 'Hashtbl\.find\b' lib/ --type ml -g '!test/' || true)
for f in $files_with_find; do
  if ! rg -q 'Hashtbl\.find_opt\b' "$f"; then
    # Allow if there's a comment justifying it
    if ! rg -q 'SIL-OK\|Hashtbl\.find is safe here\|Not_found is handled' "$f"; then
      echo "WARN: $f uses Hashtbl.find without find_opt fallback (add Hashtbl.find_opt or SIL-OK comment)"
    fi
  fi
done

# 4. Option.get without guard
echo "=== Scan: naked Option.get ==="
matches=$(rg -n 'Option\.get\b' lib/ --type ml -g '!test/' || true)
if [ -n "$matches" ]; then
  echo "WARN: Option.get found (prefer Option.value or pattern match):"
  echo "$matches" | head -20
fi

if [ "$exit_code" -eq 0 ]; then
  echo "=== SIL gate: PASS (no critical silent failures detected) ==="
else
  echo "=== SIL gate: FAIL ==="
fi

exit "$exit_code"
