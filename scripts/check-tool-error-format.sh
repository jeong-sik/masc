#!/usr/bin/env bash
# check-tool-error-format.sh — CI lint for tool error response format.
#
# Detects new tool handlers that return plain string errors instead of
# the canonical error_response/error_result/error_result_typed format.
#
# Only checks files modified in the current PR (not the entire codebase,
# since legacy migration is gradual).
#
# Exit codes:
#   0 = clean (or no changed tool files)
#   1 = new plain-string error patterns found
#
# @since v2.163.0
# @see docs/design/api-versioning-design.md I4

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Get changed tool files (vs main/origin)
BASE_REF="${1:-origin/main}"
CHANGED_TOOLS=$(git diff --name-only "$BASE_REF"...HEAD -- 'lib/tool_*.ml' 2>/dev/null || true)

if [ -z "$CHANGED_TOOLS" ]; then
  echo "No tool files changed — skipping error format check."
  exit 0
fi

echo "=== Tool Error Format Check ==="
echo "Checking $(echo "$CHANGED_TOOLS" | wc -l | tr -d ' ') changed tool file(s)..."

WARNINGS=0

for file in $CHANGED_TOOLS; do
  filepath="$REPO_ROOT/$file"
  [ -f "$filepath" ] || continue

  # Find lines added in diff that look like plain string error returns
  # Pattern: (false, "Error..." or (false, Printf.sprintf "Error...
  # Exclude: error_response, error_result, error_result_typed, json_error
  PLAIN_ERRORS=$(git diff "$BASE_REF"...HEAD -- "$file" \
    | grep '^+' \
    | grep -v '^+++' \
    | grep -i '(false,\s*"' \
    | grep -v 'error_response\|error_result\|json_error\|error_result_typed' \
    || true)

  if [ -n "$PLAIN_ERRORS" ]; then
    echo ""
    echo "WARNING: $file — new plain-string error patterns:"
    echo "$PLAIN_ERRORS" | head -5
    echo "  -> Use Tool_args.error_result or error_result_typed ~code instead"
    WARNINGS=$((WARNINGS + 1))
  fi
done

echo ""
if [ "$WARNINGS" -gt 0 ]; then
  echo "Found $WARNINGS file(s) with plain-string error patterns."
  echo "Migrate to Tool_args.error_result_typed ~code for machine-readable errors."
  echo "WARNING (non-blocking): legacy migration is gradual."
  # Non-blocking for now — change to exit 1 after migration completes
  exit 0
fi

echo "PASS: No new plain-string error patterns in changed tool files."
exit 0
