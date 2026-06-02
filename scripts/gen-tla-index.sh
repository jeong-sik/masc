#!/usr/bin/env bash
# gen-tla-index.sh — Generate specs/INDEX.md from the TLA+ spec tree.
#
# Reads:
#   specs/**/*.tla   spec sources
#   specs/**/*.cfg   TLC model-checking configs (clean + buggy pairs)
# Writes (to stdout by default):
#   A markdown index with per-directory tables and aggregate statistics.
#
# Usage:
#   scripts/gen-tla-index.sh                 # print to stdout
#   scripts/gen-tla-index.sh > specs/INDEX.md
#
# Exit codes:
#   0  index emitted
#   2  specs/ directory missing
#
# Dependencies: bash, find, git, awk, sed, sort, wc, head. No new tools.

set -euo pipefail

# Keep generated row ordering identical across macOS and Linux runners.
export LC_ALL=C

# --- Resolve repo root --------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if [[ ! -d specs ]]; then
  echo "error: specs/ not found at $REPO_ROOT" >&2
  exit 2
fi

# --- Helpers ------------------------------------------------------------------

# Detect spec kind by scanning the first 80 lines.
# Echoes one of: ttrace | manual
detect_kind() {
  local f="$1"
  local base
  base="$(basename "$f")"
  # File-name conventions used by the TLC trace exporter.
  if [[ "$base" == *TTrace* ]] || [[ "$base" == *Trace_*.tla ]]; then
    echo "ttrace"
    return
  fi
  # Heuristic: TLC-emitted traces usually contain "Trace specification" or
  # "@@ Trace" or refer to a parent module via TT_xxx variables.
  if head -80 "$f" 2>/dev/null | grep -qE "^\\\\\\* (Trace specification|TLC counterexample)"; then
    echo "ttrace"
    return
  fi
  echo "manual"
}

# Extract MODULE name from a .tla file. Falls back to the basename.
module_name() {
  local f="$1"
  local m
  m="$(grep -m1 -oE "MODULE[[:space:]]+[A-Za-z0-9_]+" "$f" 2>/dev/null | head -1 | awk '{print $2}')"
  if [[ -z "$m" ]]; then
    basename "$f" .tla
  else
    echo "$m"
  fi
}

# Collect INVARIANTS / PROPERTIES from a .cfg file.
# Strips comments (lines starting with \*). Joins names with a comma.
extract_invariants() {
  local cfg="$1"
  awk '
    BEGIN { mode = "" }
    function flush_one(name, tag) {
      sub(/\\\*.*$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == "" || name ~ /^=+$/ || name ~ /^-+$/) return
      out = (out == "") ? (tag ":" name) : (out ", " tag ":" name)
    }
    /^[[:space:]]*\\\*/ { next }                         # skip line-comment

    # Single-line forms: "INVARIANT Foo" / "PROPERTY Bar" (TLC accepts either).
    /^[[:space:]]*INVARIANTS?[[:space:]]+[A-Za-z0-9_]+/ {
      n = $0; sub(/^[[:space:]]*INVARIANTS?[[:space:]]+/, "", n)
      flush_one(n, "inv"); mode = ""; next
    }
    /^[[:space:]]*PROPERTIES?[[:space:]]+[A-Za-z0-9_]+/ {
      n = $0; sub(/^[[:space:]]*PROPERTIES?[[:space:]]+/, "", n)
      flush_one(n, "prop"); mode = ""; next
    }

    # Block forms: "INVARIANTS\n  Foo\n  Bar".
    /^[[:space:]]*INVARIANTS?[[:space:]]*$/ { mode = "I"; next }
    /^[[:space:]]*PROPERTIES?[[:space:]]*$/ { mode = "P"; next }

    # Any other top-level keyword closes the current block.
    /^[[:space:]]*(SPECIFICATION|CONSTANTS?|CONSTANT|INIT|NEXT|VIEW|SYMMETRY|CHECK_DEADLOCK|CONSTRAINT|ACTION_CONSTRAINT|ALIAS)([[:space:]]|$)/ { mode = ""; next }

    {
      if (mode == "I" || mode == "P") {
        line = $0
        sub(/\\\*.*$/, "", line)                          # strip inline comment
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line != "") flush_one(line, (mode == "I") ? "inv" : "prop")
      }
    }
    END { print out }
  ' "$cfg"
}

# Stable source content fingerprint for a file. Falls back to "-".
source_hash() {
  local f="$1"
  local h
  h="$(git hash-object -- "$f" 2>/dev/null | cut -c1-12 || true)"
  if [[ -z "$h" ]]; then echo "-"; else echo "$h"; fi
}

# Markdown-escape pipes inside table cells.
md_escape() { local s="$1"; printf '%s' "${s//|/\\|}"; }

# Replace "/" with "__" for use as a flat filesystem key.
group_key_for() { local s="$1"; printf '%s' "${s//\//__}"; }

is_tracked() {
  local f="$1"
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1
}

# --- Pass 1: enumerate specs and collect per-directory data -------------------

# Use a temp dir for grouping by directory.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TOTAL=0
TOTAL_MANUAL=0
TOTAL_TTRACE=0
TOTAL_DIRS=0
TOTAL_CFG=0
TOTAL_CFG_BUGGY=0

while IFS= read -r tla; do
  TOTAL=$((TOTAL + 1))
  dir="$(dirname "$tla")"
  base="$(basename "$tla" .tla)"
  kind="$(detect_kind "$tla")"
  case "$kind" in
    ttrace) TOTAL_TTRACE=$((TOTAL_TTRACE + 1)) ;;
    *)      TOTAL_MANUAL=$((TOTAL_MANUAL + 1)) ;;
  esac

  # Match .cfg pairs for this spec.
  clean_cfg="$dir/$base.cfg"
  cfgs=()
  if [[ -f "$clean_cfg" ]] && is_tracked "$clean_cfg"; then cfgs+=("$clean_cfg"); fi
  while IFS= read -r extra; do
    [[ -n "$extra" ]] && cfgs+=("$extra")
  done < <(
    find "$dir" -maxdepth 1 -type f -name "${base}-*.cfg" 2>/dev/null \
      | while IFS= read -r extra; do
          is_tracked "$extra" && printf '%s\n' "$extra"
        done \
      | sort
  )

  # Aggregate cfg invariants.
  cfg_count=0
  buggy_count=0
  inv_summary=""
  for c in "${cfgs[@]:-}"; do
    [[ -z "$c" ]] && continue
    cfg_count=$((cfg_count + 1))
    cb="$(basename "$c" .cfg)"
    if [[ "$cb" == *-buggy* ]]; then
      buggy_count=$((buggy_count + 1))
    fi
    inv="$(extract_invariants "$c")"
    if [[ -n "$inv" ]]; then
      label="${cb#"${base}"}"; label="${label#-}"
      [[ -z "$label" ]] && label="clean"
      inv_summary+="${label}={${inv}} "
    fi
  done
  TOTAL_CFG=$((TOTAL_CFG + cfg_count))
  TOTAL_CFG_BUGGY=$((TOTAL_CFG_BUGGY + buggy_count))
  inv_summary="${inv_summary% }"
  [[ -z "$inv_summary" ]] && inv_summary="-"

  module="$(module_name "$tla")"
  revision="$(source_hash "$tla")"

  # Persist row, grouped by dir.
  group_key="$(group_key_for "$dir")"
  row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$base.tla" "$module" "$kind" "$cfg_count" "$buggy_count" "$inv_summary" "$revision")"
  printf '%s\n' "$row" >> "$WORKDIR/$group_key.rows"
  echo "$dir" >> "$WORKDIR/dirs.list"
done < <(
  find specs -name "*.tla" -type f \
    | while IFS= read -r tla; do
        is_tracked "$tla" && printf '%s\n' "$tla"
      done \
    | sort
)

# Sort and count distinct directories.
TOTAL_DIRS="$(sort -u "$WORKDIR/dirs.list" | wc -l | tr -d ' ')"

# --- Pass 2: emit Markdown ----------------------------------------------------

GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_HEAD="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

cat <<EOF
<!--
This file is auto-generated by scripts/gen-tla-index.sh.
Edit the generator, not this file. Re-run: scripts/gen-tla-index.sh > specs/INDEX.md
-->

# TLA+ Spec Index

Generated: $GENERATED_AT (HEAD: $GIT_HEAD)

Source of truth: \`specs/\`. Run \`scripts/gen-tla-index.sh > specs/INDEX.md\` to refresh.

## Statistics

| Metric | Value |
|--------|-------|
| Total .tla files | $TOTAL |
| Manual specs | $TOTAL_MANUAL |
| TTrace (auto-generated) | $TOTAL_TTRACE |
| Directories | $TOTAL_DIRS |
| Total .cfg files | $TOTAL_CFG |
| Buggy .cfg (bug-model pair) | $TOTAL_CFG_BUGGY |

\`kind\` column: **manual** = hand-authored spec; **ttrace** = TLC counterexample export (\`*TTrace*\` or trace marker in header). \`cfg\`/\`buggy\` columns count companion \`.cfg\` files. \`invariants/properties\` lists names per cfg label (\`clean=...\`, \`buggy=...\`). \`source hash\` is the tracked \`.tla\` blob fingerprint.

## Specs by Directory

EOF

# Iterate directories in stable order.
sort -u "$WORKDIR/dirs.list" | while IFS= read -r dir; do
  group_key="$(group_key_for "$dir")"
  rows_file="$WORKDIR/$group_key.rows"
  [[ -f "$rows_file" ]] || continue
  spec_count="$(wc -l <"$rows_file" | tr -d ' ')"

  printf '### %s (%s specs)\n\n' "$dir" "$spec_count"
  printf '| File | Module | Kind | cfg | buggy | Invariants / Properties | Source Hash |\n'
  printf '|------|--------|------|-----|-------|-------------------------|---------------|\n'

  sort "$rows_file" | while IFS=$'\t' read -r file module kind cfg_count buggy_count inv_summary modified; do
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
      "$(md_escape "$file")" \
      "$(md_escape "$module")" \
      "$(md_escape "$kind")" \
      "$cfg_count" \
      "$buggy_count" \
      "$(md_escape "$inv_summary")" \
      "$modified"
  done
  printf '\n'
done

cat <<'EOF'
## Notes

- Bug-model pattern: each spec under `specs/bug-models/` and clean/buggy pairs under `specs/keeper-state-machine/` (and others) follow the convention from `software-development.md` (TLA+ Bug Model — clean must pass, buggy must violate the same invariant).
- TLC entry point: `specs/Makefile` (`make check-all` etc.). CI wiring lives in `scripts/tla-check.sh`.
- Discrepancy log: external strategy notes claimed "19 specs"; the real tree currently holds the count above. Re-run this script to update after spec additions.
EOF
