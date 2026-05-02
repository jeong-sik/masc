#!/usr/bin/env bash
# Detect hardcoded hex/rgba colors in dashboard TypeScript Canvas 2D and
# Cytoscape.js rendering contexts.
#
# Canvas 2D and Cytoscape.js do not support CSS var() strings.  After the
# token-compliance migration (PR #12749) replaced 28 hardcoded colors with
# cssVar()/resolveCssVar() helpers, this gate prevents regressions.
#
# Signal (Canvas 2D — any .ts file):
#   ctx.fillStyle  assigned a hex literal (#rrggbb) or rgb()/rgba() call.
#   ctx.strokeStyle assigned a hex literal (#rrggbb) or rgb()/rgba() call.
#
# Signal (Cytoscape.js — only files that import cytoscape):
#   A recognised Cytoscape color property (color, background-color,
#   border-color, line-color, target-arrow-color, source-arrow-color,
#   overlay-color, text-background-color, mid-target-arrow-color,
#   mid-source-arrow-color) assigned a hex literal or rgb()/rgba() call.
#
# Allowed (never flagged):
#   - var(--...) CSS variable references in string position
#   - cssVar() / resolveCssVar() function-call expressions
#   - Fallback-dict entries where the key starts with '--' (TOKEN_FALLBACKS
#     pattern in cytoscape-fsm.ts — graceful degradation, not design choice)
#
# Allowlist: scripts/lint/no-hardcoded-colors-dashboard.allowlist
#   path:line   — line-anchored debt entry
#
# Exit codes:
#   0 — clean
#   1 — new violations (not in allowlist)
#   2 — stale allowlist entries (entry no longer maps to a detected violation)
#
# Reference: issue #hardcoded-colors-ci, PR #12749 (token migration),
#            scripts/lint/no-unknown-permissive-default.sh (pattern template).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

ALLOWLIST_FILE="${ALLOWLIST_FILE:-scripts/lint/no-hardcoded-colors-dashboard.allowlist}"

violations=0
files_scanned=0
detected_keys=()

# ---------------------------------------------------------------------------
# Pattern constants
# ---------------------------------------------------------------------------

# Canvas 2D: ctx.fillStyle or ctx.strokeStyle = '#hex' or 'rgba?(...)'
readonly CANVAS_HEX="ctx\.(fillStyle|strokeStyle)[[:space:]]*=[[:space:]]*['\"]#[0-9a-fA-F]{3,8}['\"]"
readonly CANVAS_RGBA="ctx\.(fillStyle|strokeStyle)[[:space:]]*=[[:space:]]*['\"]rgba?\("

# Cytoscape color properties (these only carry semantic color values when
# inside a Cytoscape stylesheet — the property names are distinctive enough
# that some (line-color, target-arrow-color, overlay-color …) are
# Cytoscape-exclusive, while broader names (color, background-color,
# border-color) are scoped to files that import Cytoscape, see below).
readonly CY_COLOR_PROPS="'?(color|background-color|border-color|line-color|target-arrow-color|source-arrow-color|overlay-color|text-background-color|mid-target-arrow-color|mid-source-arrow-color)'?"
readonly CY_HEX="${CY_COLOR_PROPS}[[:space:]]*:[[:space:]]*['\"]#[0-9a-fA-F]{3,8}['\"]"
readonly CY_RGBA="${CY_COLOR_PROPS}[[:space:]]*:[[:space:]]*['\"]rgba?\("

# Exclusion pattern: skip lines where the RHS contains var(--, cssVar(, or
# resolveCssVar( (i.e. the value is already token-compliant).
# Also skip TOKEN_FALLBACKS-style dict entries where the key begins with '--'
# (those hex values are *fallback* literals, not design-system choices).
readonly ALLOW_RHS="var\(--|cssVar\(|resolveCssVar\("
# Fallback-dict pattern: key is a CSS-var name (starts with '--').
readonly ALLOW_KEY="^[[:space:]]*'--"

# ---------------------------------------------------------------------------
# scan_file — emit "file<TAB>line<TAB>content" for each violation
# ---------------------------------------------------------------------------
scan_file() {
  local file="$1"
  local is_cy_file="$2"   # "1" if the file imports cytoscape

  # Pass 1: Canvas 2D violations (all TypeScript files).
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    echo "$match"
  done < <(grep -nE "${CANVAS_HEX}" "$file" 2>/dev/null | grep -Ev "${ALLOW_RHS}" || true)

  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    echo "$match"
  done < <(grep -nE "${CANVAS_RGBA}" "$file" 2>/dev/null | grep -Ev "${ALLOW_RHS}" || true)

  # Pass 2: Cytoscape color-property violations (only in Cytoscape files).
  [[ "$is_cy_file" != "1" ]] && return

  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    # Skip fallback-dict entries (key starts with '--').
    echo "$match" | grep -qE "${ALLOW_KEY}" && continue
    echo "$match"
  done < <(grep -nE "${CY_HEX}" "$file" 2>/dev/null | grep -Ev "${ALLOW_RHS}" || true)

  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    echo "$match" | grep -qE "${ALLOW_KEY}" && continue
    echo "$match"
  done < <(grep -nE "${CY_RGBA}" "$file" 2>/dev/null | grep -Ev "${ALLOW_RHS}" || true)
}

# ---------------------------------------------------------------------------
# Main scan loop
# ---------------------------------------------------------------------------
while IFS= read -r -d '' file; do
  files_scanned=$((files_scanned + 1))

  # Determine if this file imports cytoscape.
  is_cy_file="0"
  if grep -qE "from ['\"]cytoscape['\"]|import ['\"]cytoscape['\"]|import type.*cytoscape" "$file" 2>/dev/null; then
    is_cy_file="1"
  fi

  findings=$(scan_file "$file" "$is_cy_file" || true)
  [[ -z "$findings" ]] && continue

  while IFS=: read -r linenum content; do
    [[ -z "$linenum" ]] && continue
    # linenum must be a positive integer; skip malformed lines.
    [[ "$linenum" =~ ^[0-9]+$ ]] || continue
    line_key="${file}:${linenum}"
    detected_keys+=("$line_key")

    if [[ -f "$ALLOWLIST_FILE" ]] && grep -qxF "$line_key" "$ALLOWLIST_FILE"; then
      continue
    fi

    trimmed="$(echo "$content" | sed 's/^[[:space:]]*//')"
    printf '::error file=%s,line=%s::hardcoded color in Canvas/Cytoscape context: %s\n' \
      "$file" "$linenum" "$trimmed"
    violations=$((violations + 1))
  done <<< "$findings"
done < <(find dashboard/src -type f -name '*.ts' -print0)

echo ""
echo "Scanned $files_scanned .ts files in dashboard/src/."

if [[ "$violations" -gt 0 ]]; then
  cat <<'EOF'

Found hardcoded color violation(s) above.

Why this is an anti-pattern:
  Canvas 2D (ctx.fillStyle / ctx.strokeStyle) and Cytoscape.js style objects
  do not evaluate CSS var() at runtime — they receive raw strings.  A
  hardcoded hex or rgba() literal bypasses the design-token system, making
  it invisible to theme switches and future palette migrations.

Fix options:
  1. Replace the literal with a cssVar() call:
       ctx.fillStyle = cssVar('--color-status-ok')
  2. Use resolveCssVar() for Cytoscape (resolves var at render time):
       'background-color': resolveCssVar('--slate-800')
  3. Add a fallback entry to the TOKEN_FALLBACKS dict and use the token name:
       '--my-token': '#hexvalue'   // in TOKEN_FALLBACKS
       resolveCssVar('--my-token') // in stylesheet
  4. If the hardcoding is intentional (prototype / legacy component), add
     one entry per line to scripts/lint/no-hardcoded-colors-dashboard.allowlist:
       path:line   (line-anchored; update when surrounding code changes)
     Prefer fixing over allowlisting.

Reference: PR #12749 (token migration), scripts/lint/no-unknown-permissive-default.sh
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Stale-allowlist check: entries no longer present in detected violations
# should be removed to keep the ledger accurate.
# ---------------------------------------------------------------------------
stale=0
if [[ -f "$ALLOWLIST_FILE" && "${SKIP_ALLOWLIST_VERIFY:-0}" != "1" ]]; then
  # Build a newline-delimited set of all detected keys.
  detected_set=$'\n'
  for key in "${detected_keys[@]:-}"; do
    detected_set+="${key}"$'\n'
  done

  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" =~ ^[[:space:]]*# ]] && continue
    # Trim trailing whitespace.
    entry=$(echo "$entry" | sed 's/[[:space:]]*$//')
    [[ -z "$entry" ]] && continue

    if [[ "$detected_set" != *$'\n'"$entry"$'\n'* ]]; then
      printf '::error file=%s::stale allowlist entry: %s (no hardcoded-color violation detected at this location; remove from allowlist)\n' \
        "$ALLOWLIST_FILE" "$entry"
      stale=$((stale + 1))
    fi
  done < "$ALLOWLIST_FILE"
fi

if [[ "$stale" -gt 0 ]]; then
  cat <<'EOF'

Stale allowlist entries detected.

Why this fails CI:
  The allowlist is a debt ledger of pre-existing violations. When an upstream
  fix tokenises the color (or surrounding code shifts the line number), the
  entry becomes stale and must be removed in the same PR.  Stale entries hide
  new violations and add noise to code review.

Fix: remove the listed entries from the allowlist file — mechanical edit,
no code change required.

Opt out only during an in-flight migration where the fix lands separately:
  SKIP_ALLOWLIST_VERIFY=1 bash scripts/lint/no-hardcoded-colors-dashboard.sh

EOF
  exit 2
fi

echo "No hardcoded-color violations found."
if [[ "${#detected_keys[@]}" -gt 0 ]]; then
  count="${#detected_keys[@]}"
  if [[ "$count" -eq 1 ]]; then
    echo "Allowlist debt: 1 site (allowlisted)."
  else
    echo "Allowlist debt: ${count} sites (all allowlisted)."
  fi
fi
