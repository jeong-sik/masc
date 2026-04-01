#!/usr/bin/env bash
# migration-audit.sh — MASC-MCP → OAS migration audit
# Classifies all lib/*.ml files into Active/Archive/Delete categories.
# Compatible with macOS bash 3.x (no associative arrays).
#
# Output: reports/migration-audit-YYYYMMDD.tsv
#
# Usage: ./scripts/migration-audit.sh [OUTPUT_PATH]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
TODAY="$(date +%Y%m%d)"
OUTPUT="${1:-$REPO_ROOT/reports/migration-audit-${TODAY}.tsv}"
TMPDIR_AUDIT="$REPO_ROOT/.tmp/audit-$$"
mkdir -p "$TMPDIR_AUDIT"
trap 'rm -rf "$TMPDIR_AUDIT"' EXIT

mkdir -p "$(dirname "$OUTPUT")"

echo "Auditing lib/*.ml files..." >&2
echo "Temp dir: $TMPDIR_AUDIT" >&2

# --- Step 1: Precompute OAS import files ---
echo "Step 1/4: Scanning OAS imports..." >&2
grep -rl 'Agent_sdk\|Oas\.\|Oas_' "$LIB_DIR"/*.ml 2>/dev/null \
  | xargs -I{} basename {} \
  | sort > "$TMPDIR_AUDIT/oas_files.txt" 2>/dev/null || touch "$TMPDIR_AUDIT/oas_files.txt"

# --- Step 2: Precompute reference counts ---
echo "Step 2/4: Computing reference counts (this takes a while)..." >&2
ref_file="$TMPDIR_AUDIT/ref_counts.txt"
: > "$ref_file"

for ml_file in "$LIB_DIR"/*.ml; do
  base="$(basename "$ml_file" .ml)"
  # OCaml module name: capitalize first letter
  first="$(echo "$base" | cut -c1 | tr '[:lower:]' '[:upper:]')"
  rest="$(echo "$base" | cut -c2-)"
  module_name="${first}${rest}"
  # Count references from other files
  count=$(grep -rl "${module_name}\." "$LIB_DIR"/*.ml 2>/dev/null | grep -cv "$(basename "$ml_file")" || echo 0)
  echo "${base}	${count}" >> "$ref_file"
done

# --- Step 3: Build classification ---
echo "Step 3/4: Classifying files..." >&2

# Header
printf "file\tlines\tlast_commit_date\tdays_since_change\thas_oas_import\tref_count\tcategory\tsuggested_action\treason\n" > "$OUTPUT"

total=0
active=0
archive=0
delete_count=0
now_epoch=$(date +%s)

for ml_file in "$LIB_DIR"/*.ml; do
  base="$(basename "$ml_file" .ml)"
  filename="$(basename "$ml_file")"
  lines=$(wc -l < "$ml_file" | tr -d ' ')

  # Last commit date
  last_date=$(cd "$REPO_ROOT" && git log -1 --format=%ci -- "lib/$filename" 2>/dev/null | cut -d' ' -f1)
  if [ -z "$last_date" ]; then
    last_date="unknown"
    days_since=999
  else
    last_epoch=$(date -j -f "%Y-%m-%d" "$last_date" +%s 2>/dev/null || date -d "$last_date" +%s 2>/dev/null || echo 0)
    days_since=$(( (now_epoch - last_epoch) / 86400 ))
  fi

  # OAS import check
  has_oas="no"
  if grep -q "^${filename}$" "$TMPDIR_AUDIT/oas_files.txt" 2>/dev/null; then
    has_oas="yes"
  fi

  # Reference count
  ref_count=$(grep "^${base}	" "$ref_file" | cut -f2)
  ref_count="${ref_count:-0}"

  # Category
  category="infrastructure"
  case "$base" in
    tool_*) category="tool" ;;
    team_session*) category="team_session" ;;
    keeper_*) category="keeper" ;;
    dashboard_*) category="dashboard" ;;
    *_types*|*_enums*) category="types" ;;
    masc_pb) category="generated" ;;
    cp_*) category="command_plane" ;;
    autonomy_*) category="autonomy" ;;
    voice_*) category="voice" ;;
    trpg_*) category="trpg" ;;
    a2a_*) category="a2a" ;;
    agent_swarm*) category="agent_swarm" ;;
    mitosis*) category="lifecycle" ;;
    oas_*) category="oas_bridge" ;;
    context_*) category="context" ;;
    config*|env_config*) category="config" ;;
    server_*|backend*) category="server" ;;
    succession*|verifier*|worker_oas*) category="oas_bridge" ;;
  esac

  # Classification logic
  action="archive"
  reason="default"

  if [ "$category" = "generated" ]; then
    action="active"
    reason="generated_code"
  elif [ "$has_oas" = "yes" ]; then
    action="active"
    reason="oas_integrated"
  elif [ "$days_since" -lt 90 ]; then
    action="active"
    reason="recently_modified"
  elif [ "$ref_count" -ge 5 ]; then
    action="active"
    reason="high_dependency"
  elif [ "$category" = "types" ] && [ "$ref_count" -ge 1 ]; then
    action="active"
    reason="active_types"
  elif [ "$category" = "config" ]; then
    action="active"
    reason="config_module"
  elif [ "$ref_count" -eq 0 ] && [ "$days_since" -ge 180 ]; then
    action="delete"
    reason="dead_code_no_refs"
  elif [ "$ref_count" -eq 0 ]; then
    action="archive"
    reason="no_refs"
  elif [ "$ref_count" -le 2 ] && [ "$days_since" -ge 180 ]; then
    action="archive"
    reason="low_refs_stale"
  fi

  printf "%s\t%d\t%s\t%d\t%s\t%d\t%s\t%s\t%s\n" \
    "$filename" "$lines" "$last_date" "$days_since" "$has_oas" "$ref_count" "$category" "$action" "$reason" \
    >> "$OUTPUT"

  total=$((total + 1))
  case "$action" in
    active) active=$((active + 1)) ;;
    archive) archive=$((archive + 1)) ;;
    delete) delete_count=$((delete_count + 1)) ;;
  esac
done

# --- Step 4: Summary ---
echo "" >&2
echo "Step 4/4: Generating summary..." >&2

cat >&2 <<EOF

============================================
  MASC-MCP Migration Audit Report
  Date: $(date +%Y-%m-%d)
============================================

Total .ml files:  $total
  Active:         $active
  Archive:        $archive
  Delete:         $delete_count

Active LOC:
EOF
awk -F'\t' 'NR>1 && $8=="active" {sum+=$2} END {printf "  %d lines\n", sum}' "$OUTPUT" >&2

echo "" >&2
echo "=== Category Breakdown ===" >&2
awk -F'\t' 'NR>1 {cat[$7]++} END {for(c in cat) printf "  %-20s %d\n", c, cat[c]}' "$OUTPUT" | sort -t' ' -k2 -rn >&2

echo "" >&2
echo "=== Action by Category ===" >&2
awk -F'\t' 'NR>1 {printf "%s\t%s\n", $7, $8}' "$OUTPUT" \
  | sort | uniq -c | sort -rn \
  | awk '{printf "  %-25s %-10s %d\n", $2, $3, $1}' >&2

echo "" >&2
echo "=== God Files (850+ lines) ===" >&2
awk -F'\t' 'NR>1 && $2 >= 850 {printf "  %-45s %5d lines  [%s] %s\n", $1, $2, $8, $9}' "$OUTPUT" \
  | sort -t'[' -k1 -rn >&2

echo "" >&2
echo "=== Delete Candidates ===" >&2
awk -F'\t' 'NR>1 && $8=="delete" {printf "  %-45s %5d lines  refs=%d  last=%s\n", $1, $2, $6, $3}' "$OUTPUT" \
  | sort >&2

echo "" >&2
echo "=== Top Archive Candidates (by size) ===" >&2
awk -F'\t' 'NR>1 && $8=="archive" {printf "  %-45s %5d lines  refs=%d  last=%s  %s\n", $1, $2, $6, $3, $9}' "$OUTPUT" \
  | sort -t' ' -k2 -rn | head -30 >&2

echo "" >&2
echo "Output: $OUTPUT" >&2
echo "Done." >&2
