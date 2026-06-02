#!/usr/bin/env bash
# Lint for [try ... with _ -> ()] / [Result.iter_error ~f:ignore]
# anti-patterns.
#
# Step 0b of the bloodflow restoration plan introduced
# [Telemetry_observe.observe_or_fail] / [observe_or_default] as the
# typed alternative. This script reports remaining call sites so the
# baseline can be ratcheted down over time.
#
# Patterns flagged:
#   - try ... with _ -> ()            — silent unit-return swallow
#   - try ... with _exn -> ()         — silent unit-return swallow (named)
#   - Result.iter_error ~f:ignore     — Result.Error swallowed
#   - Result.iter_error (fun _ -> ()) — Result.Error swallowed (lambda)
#
# Patterns NOT flagged (intentional):
#   - with _ -> None / [] / false / 0 — option/list/bool/int defaults
#     are a conversion idiom, not a unit-side-effect swallow.
#   - lines tagged [@observe-allowed: <reason>] — opt-out marker.
#   - lib/telemetry_observe.{ml,mli}    — the wrapper itself.
#   - lib/**/test/, test/, **/_test_*.ml — test code.
#
# Usage:
#   scripts/check_silent_failure.sh           — warn-only, exit 0
#   scripts/check_silent_failure.sh --strict  — fail on findings, exit 1
#
# Cross-reference:
#   - lib/telemetry_observe.{ml,mli}
#   - planning/claude-plans/me-workspace-yousleepwhen-masc-mcp-hashed-pretzel.md (Step 0b)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

STRICT=0
if [ "${1:-}" = "--strict" ]; then
  STRICT=1
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "rg (ripgrep) not found — install via 'brew install ripgrep'." >&2
  exit 2
fi

# Search scopes: lib/ and bin/ only. test/ paths are excluded by glob below.
SEARCH_PATHS=(lib bin)

# Patterns to flag. Each is an extended regex anchored on the silent
# tail (-> () or ~f:ignore / (fun _ -> ())). Captured separately so the
# report tags each finding with which anti-pattern it tripped.
declare -a FINDINGS=()

scan_pattern() {
  local label="$1"
  local pattern="$2"

  # rg --vimgrep gives file:line:col:line_text — easy to filter and report.
  # -g excludes glob patterns the lint should ignore.
  while IFS= read -r line; do
    [ -n "$line" ] && FINDINGS+=("[${label}] ${line}")
  done < <(
    rg --vimgrep -e "$pattern" \
       -g '!lib/telemetry_observe.{ml,mli}' \
       -g '!**/test/**' \
       -g '!**/_test_*.ml' \
       -g '!**/test_*.ml' \
       "${SEARCH_PATHS[@]}" 2>/dev/null \
    | rg -v '@observe-allowed' || true
  )
}

# Named exception handlers (e.g., [with End_of_file -> ()]) are
# intentionally NOT flagged: catching a specific exception is structured
# error handling, not a blanket swallow. Only anonymous-shaped patterns
# (_, _exn, _e, _x — identifiers that start with underscore) qualify.
scan_pattern "try-unit-swallow"     'try .* with _[a-z_]* -> \(\)'
scan_pattern "iter_error-ignore"    'Result\.iter_error[[:space:]]+~f:ignore'
scan_pattern "iter_error-lambda"    'Result\.iter_error[[:space:]]+\(fun _ -> \(\)\)'

# Dedupe: rg may report the same line under more than one regex when
# patterns overlap; collapse to a unique set keyed on file:line:col.
if [ "${#FINDINGS[@]}" -gt 0 ]; then
  IFS=$'\n' read -r -d '' -a FINDINGS < <(printf '%s\n' "${FINDINGS[@]}" | awk '!seen[$0]++' && printf '\0')
fi

COUNT="${#FINDINGS[@]}"

echo "check_silent_failure: ${COUNT} silent-failure anti-pattern site(s) found."

if [ "$COUNT" -gt 0 ]; then
  echo
  echo "Findings:"
  for f in "${FINDINGS[@]}"; do
    echo "  $f"
  done
  echo
  echo "Remediation:"
  echo "  - Replace [try ... with _ -> ()] with"
  echo "      Telemetry_observe.observe_or_fail ~kind:\"<descriptive>\" (fun () -> ...)"
  echo "    or [Telemetry_observe.observe_or_default ~kind ~default ...]"
  echo "    when a value-returning fall-back is needed."
  echo "  - Replace [Result.iter_error ~f:ignore] with explicit handling:"
  echo "      Result.iter_error r ~f:(fun e -> Log.<Module>.warn \"%s\" e)"
  echo "  - To accept a finding intentionally, add [@observe-allowed: <reason>]"
  echo "    on the same line."
fi

if [ "$STRICT" -eq 1 ] && [ "$COUNT" -gt 0 ]; then
  exit 1
fi

exit 0
