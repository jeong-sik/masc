#!/usr/bin/env bash
# Detect #8605 family: match-expressions that parse string literals from the
# wire and silently map unknown input to a concrete constructor.
#
# Signal:
#   1. A match arm `| "<literal>" -> ...` exists (the match is parsing strings).
#   2. A subsequent wildcard `| _ -> X` in the same block returns a concrete
#      constructor (anything except None / Error / Some / Ok / Unknown / Other /
#      Unspecified / Null / Nil / *_unknown / *_other / Module.lowercase_fn).
#
# Allowlist entry forms (both accepted):
#   path:line        — legacy. Fragile under refactor: an upstream insertion
#                      shifts the line number and the entry goes stale even
#                      when the pattern is still there.
#   path::symbol     — symbol-anchored. Stable across line drift. Resolves
#                      to the enclosing top-level `let <symbol>` / `and
#                      <symbol>` declaration at the violation site. Prefer
#                      this form.
#
# Exit codes:
#   0 — clean
#   1 — new violations (not in allowlist)
#   2 — stale allowlist entries (pattern no longer present at listed location)
#
# Reference: #8605 (family), #8832 (latest instance), event_kind.mli (fix template).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

ALLOWLIST_FILE="${ALLOWLIST_FILE:-scripts/lint/no-unknown-permissive-default.allowlist}"

violations=0
files_scanned=0
detected_keys=()

# awk scans each .ml file:
#   - Tracks the enclosing top-level `let`/`and` symbol at each line.
#   - Tracks whether the last ~40 lines contained a `| "literal" -> ...` arm.
#   - When a `| _ -> Capital_Constructor` line appears AND the exclusion
#     list doesn't match, emit `file<TAB>line<TAB>symbol<TAB>content`.
#
# Using TAB as a field separator because OCaml `content` may embed `:` in
# type annotations; `symbol` is always a plain identifier or `<top>`.
scan_file() {
  awk '
    BEGIN {
      has_string_arm = 0
      arm_line = 0
      current_symbol = "<top>"
    }
    function extract_symbol(s,    n, parts, idx, sym) {
      n = split(s, parts, /[[:space:]]+/)
      idx = 2
      if (n >= 3 && parts[2] == "rec") idx = 3
      sym = parts[idx]
      # Strip anything after the identifier (args, type annotations, =, etc.).
      gsub(/[^a-zA-Z0-9_'\''].*/, "", sym)
      if (sym == "" || sym == "_") return "<top>"
      return sym
    }
    {
      line = $0

      # Track the enclosing top-level let/and binding.
      if (line ~ /^(let|and)[[:space:]]/) {
        current_symbol = extract_symbol(line)
        has_string_arm = 0
        arm_line = 0
      }

      # Track string-literal arms within recent window.
      if (line ~ /^[[:space:]]*\|[[:space:]]*"[^"]*"[[:space:]]*->/) {
        has_string_arm = 1
        arm_line = NR
      }

      # Window expiry: if more than 40 lines since last string arm, reset.
      if (has_string_arm && (NR - arm_line) > 40) {
        has_string_arm = 0
      }

      # Detect wildcard-to-constructor.
      if (has_string_arm && line ~ /^[[:space:]]*\|[[:space:]]*_[[:space:]]*->[[:space:]]*[A-Z][a-zA-Z_0-9]+/) {
        # Exclude Module.lowercase_fn (function application, not a constructor).
        if (line ~ /->[[:space:]]*[A-Z][A-Za-z_0-9.]*\.[a-z]/) next
        # Exclude safe / explicit-failure constructors.
        if (line ~ /->[[:space:]]*([A-Z][A-Za-z_0-9]*\.)*(None|Error|Some|Ok|Unknown|Other|Unspecified|Null|Nil|Reject|Fail|Failure|Invalid|Missing|Denied|Skip|Skipped|Absent|NotFound|Not_found)([^A-Za-z0-9_]|$)/) next
        if (line ~ /(_unknown|_other|_unspecified|_invalid|_missing|_error)([^A-Za-z0-9_]|$)/) next

        printf "%s\t%d\t%s\t%s\n", FILENAME, NR, current_symbol, line
      }
    }
  ' "$1"
}

while IFS= read -r -d '' file; do
  files_scanned=$((files_scanned + 1))
  findings=$(scan_file "$file" || true)
  [[ -z "$findings" ]] && continue

  while IFS=$'\t' read -r _ linenum symbol content; do
    [[ -z "$linenum" ]] && continue
    line_key="${file}:${linenum}"
    sym_key="${file}::${symbol}"
    detected_keys+=("$line_key" "$sym_key")

    if [[ -f "$ALLOWLIST_FILE" ]] && \
       { grep -qxF "$line_key" "$ALLOWLIST_FILE" || grep -qxF "$sym_key" "$ALLOWLIST_FILE"; }; then
      continue
    fi

    trimmed="$(echo "$content" | sed 's/^[[:space:]]*//')"
    printf '::error file=%s,line=%d::#8605 family: permissive default in string-parsing match (symbol=%s): %s\n' \
      "$file" "$linenum" "$symbol" "$trimmed"
    violations=$((violations + 1))
  done <<< "$findings"
done < <(find lib -type f -name '*.ml' -print0)

echo ""
echo "Scanned $files_scanned .ml files."

if [[ "$violations" -gt 0 ]]; then
  cat <<'EOF'

Found #8605 family violation(s) above.

Why this is an anti-pattern:
  A match expression that parses string literals from the wire (tool args,
  config, JSON) and falls through `| _ -> SomeConcreteDefault` silently
  accepts garbage. The caller cannot distinguish "user passed X" from
  "user passed nonsense, coerced to X". Telemetry, validation, and variant
  exhaustiveness are all bypassed.

Fix options:
  1. Sound-partial parser: return `option` (None for unknown). Caller chooses
     fail-open / fail-closed policy. See lib/coord/event_kind.mli for the
     reference template.
  2. Explicit `Unknown of string` variant: preserves the wire string for
     diagnosis while making the unknown case visible to downstream matches.
  3. If the coercion is intentional and well-documented, add one entry per
     line to scripts/lint/no-unknown-permissive-default.allowlist:
       path::symbol   (preferred — stable across line drift)
       path:line      (legacy — fragile)
     Prefer fixing.

EOF
  exit 1
fi

# Self-verify: fail when an allowlist entry no longer maps to a detected
# violation (upstream fix eliminated it, or — with symbol anchors — the
# symbol was renamed / removed). Symbol form eliminates the line-drift
# false-stale class that the `path:line` form exhibits (cycle 26 / cycle 35).
#
# Opt out with SKIP_ALLOWLIST_VERIFY=1 during a transient in-flight migration
# that lists the location before the fix lands.
stale=0
if [[ -f "$ALLOWLIST_FILE" && "${SKIP_ALLOWLIST_VERIFY:-0}" != "1" ]]; then
  detected_set=$'\n'
  for key in "${detected_keys[@]:-}"; do
    detected_set+="${key}"$'\n'
  done
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" =~ ^[[:space:]]*# ]] && continue
    # Trim trailing whitespace.
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue

    if [[ "$detected_set" != *$'\n'"$entry"$'\n'* ]]; then
      printf '::error file=%s::stale allowlist entry: %s (no #8605 family pattern detected at this location; remove from allowlist)\n' \
        "$ALLOWLIST_FILE" "$entry"
      stale=$((stale + 1))
    fi
  done < "$ALLOWLIST_FILE"
fi

if [[ "$stale" -gt 0 ]]; then
  cat <<'EOF'

Stale allowlist entries detected.

Why this fails CI:
  The allowlist is a debt ledger of pre-existing #8605 family sites. When
  an upstream fix eliminates the pattern (or a symbol-anchored entry loses
  its symbol via rename/removal), the entry must be removed in the same
  PR. Silently-stale entries turn the ledger into noise and let new
  violations hide behind old listings (cycle 26 / cycle 35 drift
  incidents).

Fix: remove the listed entries from the allowlist file — mechanical edit,
no code change required.

Opt out only for transient in-flight migrations:
  SKIP_ALLOWLIST_VERIFY=1 bash scripts/lint/no-unknown-permissive-default.sh

EOF
  exit 2
fi

echo "No #8605 family violations found."
if [[ "${#detected_keys[@]}" -gt 0 ]]; then
  # Each violation contributes 2 keys (line + symbol). Report unique sites.
  site_count=$(( ${#detected_keys[@]} / 2 ))
  if [[ "$site_count" -eq 1 ]]; then
    echo "Allowlist debt: 1 site (allowlisted)."
  else
    echo "Allowlist debt: ${site_count} sites (all allowlisted)."
  fi
fi
