#!/usr/bin/env bash
# Read-only audit of keeper credential dual-identity state.
#
# Background
#   Pre-#9737 each keeper could hold two distinct credential files on
#   disk: a bare-nickname file (sangsu.json) and a canonical wrapper
#   file (keeper-sangsu-agent.json) with different bearer tokens. The
#   load_credential_with_aliases first-hit dispatcher routed by alias
#   and silently picked one identity per request, downstream of which
#   was the 119-event silent_auth_token_resolve_error / token_mismatch
#   burst documented in #10491 (P2-a).
#
#   #9737 (UUID-based identity Phase 3) reshaped on-disk state: name
#   files become redirect stubs — {"redirect_to": "<uuid>.json"} —
#   that point at a single UUID-named credential file. Both shapes
#   ("sangsu.json" and "keeper-sangsu-agent.json") are expected to
#   redirect to the SAME UUID file. When they redirect to DIFFERENT
#   UUID files, the dual identity is preserved at the UUID level even
#   though the stub layer is in place — that is the residual split-
#   brain state this script detects.
#
# What this script does
#   For every name-file (non-UUID basename) that contains a
#   "redirect_to" field, it groups by stem (sangsu / scholar / ...)
#   and checks that all shapes for the same stem redirect to the same
#   UUID. Direct (non-redirecting) credential files are reported but
#   do not participate in the comparison.
#
# What this script does NOT do
#   No file is written, moved, or deleted. Cred files are persistent
#   operational state and the right cleanup target depends on which
#   token the live keeper subprocess is presenting at runtime — that
#   information lives in process memory, not on disk. The script
#   produces a triage report; manual decision required for any cleanup.
#
# Usage:
#   scripts/audit-keeper-credential-drift.sh [--base-path PATH] [--json]
#
# Options:
#   --base-path PATH   Server base_path (default: $HOME/me)
#   --json             Emit machine-readable JSON only (no human report)
#   -h, --help         Show this help
set -o pipefail
# Note: set -e and set -u are intentionally NOT enabled. bash 3.2
# (macOS default) (a) expands an empty array's "${arr[@]}" as an
# unbound reference even in `for ... in "${arr[@]}"; do` patterns and
# (b) terminates the audit on transient grep/test mismatches that the
# script handles explicitly. We rely on pipefail and explicit exit
# code accounting instead.

BASE_PATH="${HOME}/me"
EMIT_JSON=0

usage() {
  cat <<'EOF'
Usage: scripts/audit-keeper-credential-drift.sh [--base-path PATH] [--json]

Audits .masc/auth/agents/*.json for the dual-identity pattern where the
same logical keeper has both a bare-nickname stub and a canonical
"keeper-<name>-agent" stub redirecting to DIFFERENT UUID credential
files. Produces a triage report; never modifies files.

Exit code:
  0 — every dual stem's two shapes converge on the same UUID
      (or only direct creds without a paired shape)
  1 — split-brain detected (two shapes redirect to different UUIDs)
  2 — usage error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-path)
      shift
      [ $# -gt 0 ] || { usage; exit 2; }
      BASE_PATH="$1"
      shift
      ;;
    --json)
      EMIT_JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

AGENTS_DIR="${BASE_PATH}/.masc/auth/agents"
if [ ! -d "$AGENTS_DIR" ]; then
  printf 'No agents directory at %s\n' "$AGENTS_DIR" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required\n' >&2
  exit 2
fi

# Build tuple file with one record per name-shaped credential stub.
# Format: stem<TAB>shape<TAB>basename<TAB>kind<TAB>target
#   stem      : bare keeper short name
#   shape     : bare | canonical
#   basename  : file basename without .json
#   kind      : redirect | direct
#   target    : for redirect → target uuid basename; for direct → "(none)"
#
# UUID-named files (basename matches uuid v4 pattern) are NOT records;
# they are referenced by redirect targets and audited separately.
TUPLES_FILE=$(mktemp -t auth-cred-audit.XXXXXX)
DUAL_FILE=$(mktemp -t auth-cred-audit.dual.XXXXXX)
trap 'rm -f "$TUPLES_FILE" "$DUAL_FILE"' EXIT

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

extract_one() {
  local f="$1"
  local bn shape stem redirect
  bn=$(basename "$f" .json)
  if [[ "$bn" =~ $UUID_RE ]]; then
    return 0
  fi

  if [[ "$bn" == keeper-*-agent ]]; then
    local inner=${bn#keeper-}
    stem=${inner%-agent}
    shape=canonical
  else
    stem=$bn
    shape=bare
  fi

  redirect=$(jq -r '.redirect_to // empty' "$f" 2>/dev/null) || return 0
  if [ -n "$redirect" ]; then
    printf '%s\t%s\t%s\tredirect\t%s\n' "$stem" "$shape" "$bn" "$redirect"
  else
    printf '%s\t%s\t%s\tdirect\t(none)\n' "$stem" "$shape" "$bn"
  fi
}

while IFS= read -r -d '' f; do
  extract_one "$f" >> "$TUPLES_FILE"
done < <(find "$AGENTS_DIR" -maxdepth 1 -name '*.json' -type f -print0)

TOTAL_NAME_FILES=$(wc -l < "$TUPLES_FILE" | tr -d ' ')
TOTAL_UUID_FILES=$(find "$AGENTS_DIR" -maxdepth 1 -name '*.json' -type f \
  | while IFS= read -r f; do
      bn=$(basename "$f" .json)
      [[ "$bn" =~ $UUID_RE ]] && echo x
    done | wc -l | tr -d ' ')

# Find stems that appear in BOTH bare and canonical shapes.
awk -F'\t' '
  { shapes[$1] = shapes[$1] $2 "," }
  END {
    for (s in shapes) {
      if (shapes[s] ~ /(^|,)bare(,|$)/ && shapes[s] ~ /(^|,)canonical(,|$)/) {
        print s
      }
    }
  }
' "$TUPLES_FILE" | sort > "$DUAL_FILE"

DUAL_COUNT=$(wc -l < "$DUAL_FILE" | tr -d ' ')

if [ "$DUAL_COUNT" -eq 0 ]; then
  if [ "$EMIT_JSON" = "1" ]; then
    jq -n \
      --arg base "$BASE_PATH" \
      --argjson total_name "$TOTAL_NAME_FILES" \
      --argjson total_uuid "$TOTAL_UUID_FILES" \
      '{base_path:$base, total_name_files:$total_name, total_uuid_files:$total_uuid, dual_stems:[], split_brain_count:0, converged_count:0}'
  else
    printf 'No bare/canonical pairing detected (no stem holds both shapes).\n'
    printf 'Scanned: %d name-shaped file(s), %d UUID-shaped file(s) under %s\n' \
      "$TOTAL_NAME_FILES" "$TOTAL_UUID_FILES" "$AGENTS_DIR"
  fi
  exit 0
fi

SPLIT_BRAIN=0
CONVERGED=0
SPLIT_LIST=()
CONVERGED_LIST=()
JSON_PAIRS=()

while IFS= read -r stem; do
  bare_line=$(awk -F'\t' -v s="$stem" '$1==s && $2=="bare"      { print; exit }' "$TUPLES_FILE")
  can_line=$( awk -F'\t' -v s="$stem" '$1==s && $2=="canonical" { print; exit }' "$TUPLES_FILE")
  bare_kind=$(printf '%s' "$bare_line" | cut -f4)
  can_kind=$( printf '%s' "$can_line"  | cut -f4)
  bare_tgt=$( printf '%s' "$bare_line" | cut -f5)
  can_tgt=$(  printf '%s' "$can_line"  | cut -f5)
  bare_file=$(printf '%s' "$bare_line" | cut -f3)
  can_file=$( printf '%s' "$can_line"  | cut -f3)

  # Comparable only when BOTH sides redirect. A direct-vs-redirect mix
  # is its own anomaly worth surfacing distinctly.
  if [ "$bare_kind" = "redirect" ] && [ "$can_kind" = "redirect" ]; then
    if [ "$bare_tgt" = "$can_tgt" ]; then
      CONVERGED=$((CONVERGED + 1))
      CONVERGED_LIST+=("$stem")
      split=false
      verdict=converged
    else
      SPLIT_BRAIN=$((SPLIT_BRAIN + 1))
      SPLIT_LIST+=("$stem")
      split=true
      verdict=split_brain
    fi
  else
    # Mixed kinds — at least one side is a direct credential file.
    # Treat as split for triage purposes: dispatcher routes them as
    # different identities even if both are "valid" in isolation.
    SPLIT_BRAIN=$((SPLIT_BRAIN + 1))
    SPLIT_LIST+=("$stem")
    split=true
    verdict=mixed_kinds
  fi

  JSON_PAIRS+=("$(jq -nc \
      --arg stem "$stem" \
      --arg bare_file "$bare_file" \
      --arg can_file "$can_file" \
      --arg bare_kind "$bare_kind" \
      --arg can_kind "$can_kind" \
      --arg bare_tgt "$bare_tgt" \
      --arg can_tgt "$can_tgt" \
      --arg verdict "$verdict" \
      --argjson split "$split" \
      '{stem:$stem, bare_file:$bare_file, canonical_file:$can_file, bare_kind:$bare_kind, canonical_kind:$can_kind, bare_target:$bare_tgt, canonical_target:$can_tgt, verdict:$verdict, split_brain:$split}')")
done < "$DUAL_FILE"

if [ "$EMIT_JSON" = "1" ]; then
  pairs=$(printf '%s\n' "${JSON_PAIRS[@]}" | jq -s .)
  printf '%s' "$pairs" \
    | jq --arg base "$BASE_PATH" \
         --argjson total_name "$TOTAL_NAME_FILES" \
         --argjson total_uuid "$TOTAL_UUID_FILES" \
         --argjson split "$SPLIT_BRAIN" \
         --argjson conv "$CONVERGED" \
         '{base_path:$base, total_name_files:$total_name, total_uuid_files:$total_uuid, dual_stems:., split_brain_count:$split, converged_count:$conv}'
else
  printf '\n=== Keeper credential drift audit ===\n'
  printf 'Base path        : %s\n' "$BASE_PATH"
  printf 'Name-shaped files: %d\n' "$TOTAL_NAME_FILES"
  printf 'UUID-shaped files: %d\n' "$TOTAL_UUID_FILES"
  printf 'Dual stems       : %d (converged: %d, split-brain: %d)\n\n' \
    "$DUAL_COUNT" "$CONVERGED" "$SPLIT_BRAIN"

  if [ "$CONVERGED" -gt 0 ]; then
    printf 'Converged dual stems (#9737 UUID Phase 3 working as intended):\n'
    for s in "${CONVERGED_LIST[@]}"; do
      tgt=$(awk -F'\t' -v s="$s" '$1==s && $2=="bare" { print $5; exit }' "$TUPLES_FILE")
      printf '  - %s : both shapes -> %s\n' "$s" "$tgt"
    done
    printf '\n'
  fi

  if [ "$SPLIT_BRAIN" -gt 0 ]; then
    printf 'SPLIT-BRAIN dual stems (#10491 P2-a residual evidence):\n'
    for s in "${SPLIT_LIST[@]}"; do
      bare_line=$(awk -F'\t' -v s="$s" '$1==s && $2=="bare"      { print; exit }' "$TUPLES_FILE")
      can_line=$( awk -F'\t' -v s="$s" '$1==s && $2=="canonical" { print; exit }' "$TUPLES_FILE")
      bk=$(printf '%s' "$bare_line" | cut -f4)
      ck=$(printf '%s' "$can_line"  | cut -f4)
      bt=$(printf '%s' "$bare_line" | cut -f5)
      ct=$(printf '%s' "$can_line"  | cut -f5)
      printf '  - %s :\n' "$s"
      printf '      bare      (%s) -> %s\n' "$bk" "$bt"
      printf '      canonical (%s) -> %s\n' "$ck" "$ct"
    done
    printf '\n  Recommended manual triage:\n'
    printf '    1. Identify which UUID the live keeper subprocess actually presents\n'
    printf '       (check recent .masc/logs/*.log or the keeper subprocess env).\n'
    printf '    2. Move (do not delete) the OTHER stub to .masc/auth/agents/.retired/\n'
    printf '       so its redirect_to no longer competes for the same stem.\n'
    printf '    3. If both UUID files contain valid distinct cred records, decide\n'
    printf '       which one to keep; archive the other under .retired/.\n'
    printf '    4. Confirm the next ensure_keeper_credential cycle refreshes only\n'
    printf '       the surviving file.\n'
    printf '  Do NOT delete files automatically; a wrong delete strands the keeper\n'
    printf '  from its task queue.\n\n'
  fi
fi

if [ "$SPLIT_BRAIN" -gt 0 ]; then
  exit 1
fi
exit 0
