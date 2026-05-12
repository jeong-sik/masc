#!/usr/bin/env bash
# RFC-0071 Phase 1 advisory lint: surface new fragile-match sites.
#
# Detects single-line `| _ -> false`, `| _ -> None`, `| _ -> ()` patterns
# in lib/ OCaml sources and reports any NOT in
# scripts/lint/exhaustive-guard.allowlist as advisory warnings.
#
# Phase 1 contract: ADVISORY — always exits 0. CI surfaces findings but
# never blocks merge. Phase 5 (RFC-0071 §4) converts to blocking once
# codemod has closed the bulk of inventory and allowlist is narrowed
# to (a)-class (exn / GADT / nested find-first) sites only.
#
# Allowlist forms (both accepted):
#   path:line        — legacy line-anchor. Fragile under line drift.
#   path::symbol     — preferred symbol-anchor. Resolves to enclosing
#                      top-level `let <symbol>` / `and <symbol>`.
#
# Limits:
# - Lower-bound detector. Multi-line `_ ->` arms and `_ -> SomeCtor`
#   permissive defaults are NOT caught here — those need the typed-AST
#   codemod (WS-3, RFC-0071 §3.2).
# - Excludes lib/exec/parser/ (Menhir-generated) and */test/.
#
# Exit code: 0 (advisory). Set `BLOCKING=1` in env to honor Phase 5
# semantics ahead of time (Phase 5 PR flips the default).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

ALLOWLIST_FILE="${ALLOWLIST_FILE:-scripts/lint/exhaustive-guard.allowlist}"
BLOCKING="${BLOCKING:-0}"

# Symbol-anchor extractor (same shape as no-unknown-permissive-default.sh).
scan_file() {
  awk '
    BEGIN { current_symbol = "<top>" }
    function extract_symbol(s,    n, parts, idx, sym) {
      n = split(s, parts, /[[:space:]]+/)
      idx = 2
      if (n >= 3 && parts[2] == "rec") idx = 3
      sym = parts[idx]
      gsub(/[^a-zA-Z0-9_'\''].*/, "", sym)
      if (sym == "" || sym == "_") return "<top>"
      return sym
    }
    {
      line = $0
      if (line ~ /^(let|and)[[:space:]]/) {
        current_symbol = extract_symbol(line)
      }
      if (line ~ /^[[:space:]]*\|[[:space:]]*_[[:space:]]*->[[:space:]]*(false|None|\(\))[[:space:]]*$/) {
        printf "%s\t%d\t%s\t%s\n", FILENAME, NR, current_symbol, line
      }
    }
  ' "$1"
}

files_scanned=0
new_violations=0
allowlisted=0
detected_keys=$'\n'

while IFS= read -r -d '' file; do
  files_scanned=$((files_scanned + 1))
  findings="$(scan_file "$file" || true)"
  [[ -z "$findings" ]] && continue

  while IFS=$'\t' read -r _ linenum symbol content; do
    [[ -z "$linenum" ]] && continue
    line_key="${file}:${linenum}"
    sym_key="${file}::${symbol}"
    detected_keys+="${line_key}"$'\n'"${sym_key}"$'\n'

    if [[ -f "$ALLOWLIST_FILE" ]] && \
       { grep -qxF "$line_key" "$ALLOWLIST_FILE" 2>/dev/null \
         || grep -qxF "$sym_key" "$ALLOWLIST_FILE" 2>/dev/null; }; then
      allowlisted=$((allowlisted + 1))
      continue
    fi

    trimmed="$(printf '%s' "$content" | sed 's/^[[:space:]]*//')"
    printf '::warning file=%s,line=%d::RFC-0071 fragile-match (advisory, symbol=%s): %s\n' \
      "$file" "$linenum" "$symbol" "$trimmed"
    new_violations=$((new_violations + 1))
  done <<< "$findings"
done < <(find lib -type f -name '*.ml' \
           -not -path 'lib/exec/parser/*' \
           -not -path '*/test/*' \
           -print0)

echo "" >&2
echo "Scanned $files_scanned .ml files. allowlisted=$allowlisted, new=$new_violations." >&2

if [[ "$new_violations" -gt 0 ]]; then
  cat >&2 <<'EOF'

RFC-0071 Phase 1 (advisory): new `| _ -> false/None/()` sites detected.

Why this is flagged:
  `| _ -> false/None/()` on a closed concrete variant is the FSM Sparse
  Match anti-pattern (CLAUDE.md §"AI 코드 생성 안티패턴 #4"). New ctors
  added to the variant are silently absorbed; compiler will not flag the
  case. Past incident: keeper_registry validate_decision_transition runtime
  Assert_failure (2026-05-08).

Fix options (RFC-0071 §3.4.1):
  (b) Closed concrete variant → enumerate missing ctors explicitly.
  (c) Predicate guard → list positive arms + explicit rejection arm.
  (a) exn / GADT existential / nested find-first scan → arm-level
      [@warning "-4"] + WORKAROUND comment.

Allowlist (transient debt only, prefer fixing):
  path::symbol   — preferred, stable across line drift
  path:line      — legacy, fragile

EOF
fi

# Phase 1: always exit 0 (advisory). Phase 5 flips this to honor BLOCKING.
if [[ "$BLOCKING" == "1" && "$new_violations" -gt 0 ]]; then
  exit 1
fi
exit 0
