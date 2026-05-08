#!/usr/bin/env bash
# Detect self-referential UI-explainer prose in dashboard/src/.
#
# Background: 9 PRs across two weeks (#14219, #14275, #14280, #14283,
# #14289, #14295, #14296, #14300, #14304) removed prose paragraphs that
# described what the dashboard does — "이 화면은 ...", "...만 보여줍니다",
# "필요할 때만 펼쳐 봅니다" — instead of showing data.  After two
# rounds the pattern kept landing in new PRs, so a CI gate is the
# durable fix.
#
# Banned phrases (high-signal, low false-positive in dashboard surfaces):
#   1. "이 화면은"  — almost always followed by self-description
#   2. "이 패널은"  — same shape
#   3. "이 영역은"  — same shape
#   4. "필요할 때만" — UI behavior explainer ("필요할 때만 펼쳐 봅니다",
#                     "필요할 때만 상태를 불러오세요" patterns)
#   5. "만 보여줍니다" — scope-limiter explainer
#   6. "만 표시합니다" — scope-limiter explainer
#
# Allowed (never flagged):
#   - Comments (`//` or `/* */`) — engineering docs, not user-facing copy
#   - Test-file assertions  (already handled by file glob: only src/)
#   - Allowlist entries: scripts/lint/no-explainer-prose-dashboard.allowlist
#     (one path:line per entry, line-anchored)
#
# Exit codes:
#   0 — clean
#   1 — new violations (not in allowlist)
#   2 — stale allowlist entries
#
# Reference: PR #14289, #14300 (cleanup track),
#            scripts/lint/no-hardcoded-colors-dashboard.sh (pattern template).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

ALLOWLIST_FILE="${ALLOWLIST_FILE:-scripts/lint/no-explainer-prose-dashboard.allowlist}"

violations=0
files_scanned=0
detected_keys=()

# ---------------------------------------------------------------------------
# Banned phrases — joined into a single alternation regex for grep -E.
# ---------------------------------------------------------------------------
readonly BANNED='이 화면은|이 패널은|이 영역은|필요할 때만|만 보여줍니다|만 표시합니다'

# Lines we never flag even if they match BANNED:
#   - leading // or * (line/block comments)
readonly COMMENT_LINE='^[[:space:]]*(//|\*)'

scan_file() {
  local file="$1"
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    echo "$match"
  done < <(grep -nE "${BANNED}" "$file" 2>/dev/null | grep -Ev "${COMMENT_LINE}" || true)
}

while IFS= read -r -d '' file; do
  files_scanned=$((files_scanned + 1))

  findings=$(scan_file "$file" || true)
  [[ -z "$findings" ]] && continue

  while IFS=: read -r linenum content; do
    [[ -z "$linenum" ]] && continue
    [[ "$linenum" =~ ^[0-9]+$ ]] || continue
    line_key="${file}:${linenum}"
    detected_keys+=("$line_key")

    if [[ -f "$ALLOWLIST_FILE" ]] && grep -qxF "$line_key" "$ALLOWLIST_FILE"; then
      continue
    fi

    trimmed="$(echo "$content" | sed 's/^[[:space:]]*//')"
    printf '::error file=%s,line=%s::explainer-prose anti-pattern: %s\n' \
      "$file" "$linenum" "$trimmed"
    violations=$((violations + 1))
  done <<< "$findings"
done < <(find dashboard/src -type f \( -name '*.ts' -o -name '*.tsx' \) -not -name '*.test.ts' -not -name '*.test.tsx' -print0)

echo ""
echo "Scanned $files_scanned dashboard source files."

if [[ "$violations" -gt 0 ]]; then
  cat <<'EOF'

Found explainer-prose anti-pattern violation(s) above.

Why this is an anti-pattern:
  Self-referential prose ("이 화면은 X를 보여줍니다", "...만 표시합니다",
  "필요할 때만 펼쳐 봅니다") describes what the UI does instead of showing
  data.  Operators read it once, learn nothing new, and have to mentally skip
  it on every subsequent visit.  Headings, chip labels, button text, and
  empty-state hints already carry the same information without the wall.

Fix options:
  1. Delete the line.  The eyebrow / heading / chip below usually carries
     the same meaning more compactly.
  2. Replace the prose with a data-bearing badge (counts, timestamps, IDs).
     Example: "메시지 N · 오류 M" instead of "메시지와 오류를 펼쳐 봅니다".
  3. If the line is operationally critical (a non-obvious caveat,
     failure-mode notice, or path/file reference operators must see), it
     was probably misdetected; add to allowlist with reasoning:
       scripts/lint/no-explainer-prose-dashboard.allowlist
         path:line   (line-anchored — update when surrounding code shifts)

References:
  - PR #14289 (4 surfaces), #14300 (4 more surfaces)
  - scripts/lint/no-hardcoded-colors-dashboard.sh (pattern template)
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Stale-allowlist check
# ---------------------------------------------------------------------------
stale=0
if [[ -f "$ALLOWLIST_FILE" && "${SKIP_ALLOWLIST_VERIFY:-0}" != "1" ]]; then
  detected_set=$'\n'
  for key in "${detected_keys[@]:-}"; do
    detected_set+="${key}"$'\n'
  done

  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" =~ ^[[:space:]]*# ]] && continue
    entry=$(echo "$entry" | sed 's/[[:space:]]*$//')
    [[ -z "$entry" ]] && continue

    if [[ "$detected_set" != *$'\n'"$entry"$'\n'* ]]; then
      printf '::error file=%s::stale allowlist entry: %s (no explainer-prose violation detected at this location; remove)\n' \
        "$ALLOWLIST_FILE" "$entry"
      stale=$((stale + 1))
    fi
  done < "$ALLOWLIST_FILE"
fi

if [[ "$stale" -gt 0 ]]; then
  cat <<'EOF'

Stale allowlist entries detected.

Why this fails CI:
  The allowlist is a debt ledger of pre-existing violations. When a
  cleanup PR removes the prose (or surrounding code shifts the line
  number), the entry becomes stale and must be removed in the same PR.
  Stale entries hide new violations and add review noise.

Fix: remove the listed entries from the allowlist file.

Opt out only during an in-flight cleanup that lands separately:
  SKIP_ALLOWLIST_VERIFY=1 bash scripts/lint/no-explainer-prose-dashboard.sh
EOF
  exit 2
fi

echo "No explainer-prose violations found."
if [[ "${#detected_keys[@]}" -gt 0 ]]; then
  count="${#detected_keys[@]}"
  if [[ "$count" -eq 1 ]]; then
    echo "Allowlist debt: 1 site (allowlisted)."
  else
    echo "Allowlist debt: ${count} sites (all allowlisted)."
  fi
fi
