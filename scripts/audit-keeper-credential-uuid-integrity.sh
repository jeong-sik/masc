#!/usr/bin/env bash
# Read-only audit of UUID-based credential layout integrity.
#
# Sister script to audit-keeper-credential-drift.sh (#10706). That one
# checks that bare/canonical name stubs converge on the same UUID
# target. This one verifies the UUID layer's own structural invariants:
#
#   I1. Every redirect target exists as a real UUID file (no dangling
#       redirect stubs).
#   I2. Every UUID file is reachable from at least one redirect stub
#       (no orphan UUID files — likely legacy or pre-Phase 3 leftover).
#   I3. Each UUID file's [agent_name] is consistent with the stems of
#       its inbound redirect stubs (the UUID file's [agent_name] should
#       match either the bare stem or the canonical wrapper of any
#       redirect that points to it).
#   I4. No UUID file is shared across stems (a single UUID receiving
#       redirects from two unrelated keeper names indicates a wrong
#       redirect or cred sharing — a security boundary anomaly).
#   I5. Every UUID file declares a non-empty [token] field (Phase 3
#       contract).
#
# Triage report only — never modifies files. Token values are not read
# (only metadata: agent_name, redirect targets, file presence).
#
# Usage:
#   scripts/audit-keeper-credential-uuid-integrity.sh [--base-path PATH] [--json]
#
# Options:
#   --base-path PATH   Server base_path (default: $HOME/me)
#   --json             Emit machine-readable JSON only
#   -h, --help         Show this help
set -o pipefail
# Note: set -e and set -u are intentionally NOT enabled — see
# audit-keeper-credential-drift.sh for the bash 3.2 rationale.

BASE_PATH="${HOME}/me"
EMIT_JSON=0

usage() {
  cat <<'EOF'
Usage: scripts/audit-keeper-credential-uuid-integrity.sh [--base-path PATH] [--json]

Audits .masc/auth/agents/ for UUID-based credential layout invariants:
dangling redirects, orphan UUID files, agent_name/stem mismatch, UUID
sharing across unrelated stems, missing token. Triage report only;
never modifies files.

Exit code:
  0 — every UUID file has consistent inbound redirects + token + matched agent_name
  1 — at least one structural invariant violation detected
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

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Build a redirect map and a UUID-file inventory.
# REDIRECTS_FILE: stub_basename<TAB>stem<TAB>shape<TAB>target_uuid_basename
# UUID_FILES_FILE: uuid_basename<TAB>agent_name<TAB>has_token (true/false)
REDIRECTS_FILE=$(mktemp -t auth-cred-uuid.redirects.XXXXXX)
UUID_FILES_FILE=$(mktemp -t auth-cred-uuid.uuids.XXXXXX)
DANGLING_FILE=$(mktemp -t auth-cred-uuid.dangling.XXXXXX)
ORPHAN_FILE=$(mktemp -t auth-cred-uuid.orphan.XXXXXX)
NAME_MISMATCH_FILE=$(mktemp -t auth-cred-uuid.namemismatch.XXXXXX)
SHARED_FILE=$(mktemp -t auth-cred-uuid.shared.XXXXXX)
NO_TOKEN_FILE=$(mktemp -t auth-cred-uuid.notoken.XXXXXX)
trap 'rm -f "$REDIRECTS_FILE" "$UUID_FILES_FILE" "$DANGLING_FILE" "$ORPHAN_FILE" "$NAME_MISMATCH_FILE" "$SHARED_FILE" "$NO_TOKEN_FILE"' EXIT

while IFS= read -r -d '' f; do
  bn=$(basename "$f" .json)
  if [[ "$bn" =~ $UUID_RE ]]; then
    # UUID file — extract agent_name + token presence.
    agent_name=$(jq -r '.agent_name // empty' "$f" 2>/dev/null)
    token=$(jq -r '.token // empty' "$f" 2>/dev/null)
    has_token=false
    [ -n "$token" ] && has_token=true
    printf '%s\t%s\t%s\n' "$bn" "$agent_name" "$has_token" >> "$UUID_FILES_FILE"
  else
    # Name-shaped file — check redirect_to.
    redirect=$(jq -r '.redirect_to // empty' "$f" 2>/dev/null)
    [ -z "$redirect" ] && continue
    # Strip trailing .json from target if present
    target_bn="${redirect%.json}"
    if [[ "$bn" == keeper-*-agent ]]; then
      inner=${bn#keeper-}
      stem=${inner%-agent}
      shape=canonical
    else
      stem=$bn
      shape=bare
    fi
    printf '%s\t%s\t%s\t%s\n' "$bn" "$stem" "$shape" "$target_bn" >> "$REDIRECTS_FILE"
  fi
done < <(find "$AGENTS_DIR" -maxdepth 1 -name '*.json' -type f -print0)

TOTAL_UUID=$(wc -l < "$UUID_FILES_FILE" | tr -d ' ')
TOTAL_REDIRECTS=$(wc -l < "$REDIRECTS_FILE" | tr -d ' ')

# I1. Dangling redirects: redirect_to target not in UUID inventory.
# Note: when UUID_FILES_FILE is empty, awk's `NR==FNR` trick mis-treats
# REDIRECTS_FILE as the first file and never runs the dangling check.
# Guard with -s so an empty UUID inventory still flags every redirect.
if [ -s "$UUID_FILES_FILE" ]; then
  awk -F'\t' 'NR==FNR { uuids[$1]=1; next } !($4 in uuids) { print $1 "\t" $4 }' \
    "$UUID_FILES_FILE" "$REDIRECTS_FILE" > "$DANGLING_FILE"
else
  awk -F'\t' '{ print $1 "\t" $4 }' "$REDIRECTS_FILE" > "$DANGLING_FILE"
fi
DANGLING=$(wc -l < "$DANGLING_FILE" | tr -d ' ')

# I2. Orphan UUID files: UUID never appears as a redirect target.
# Same NR==FNR + empty-first-file caveat: when REDIRECTS_FILE is empty,
# every UUID file is by definition orphan.
if [ -s "$REDIRECTS_FILE" ]; then
  awk -F'\t' 'NR==FNR { targets[$4]=1; next } !($1 in targets) { print $1 "\t" $2 }' \
    "$REDIRECTS_FILE" "$UUID_FILES_FILE" > "$ORPHAN_FILE"
else
  awk -F'\t' '{ print $1 "\t" $2 }' "$UUID_FILES_FILE" > "$ORPHAN_FILE"
fi
ORPHAN=$(wc -l < "$ORPHAN_FILE" | tr -d ' ')

# I3. Agent_name mismatch: UUID file's agent_name does not match the
# stem (or its canonical wrapper "keeper-<stem>-agent") of any inbound
# redirect.
while IFS=$'\t' read -r uuid_bn agent_name has_token; do
  [ -z "$uuid_bn" ] && continue
  inbound_stems=$(awk -F'\t' -v u="$uuid_bn" '$4==u { print $2 }' "$REDIRECTS_FILE" | sort -u)
  [ -z "$inbound_stems" ] && continue
  ok=0
  for s in $inbound_stems; do
    if [ "$agent_name" = "$s" ] || [ "$agent_name" = "keeper-${s}-agent" ]; then
      ok=1
      break
    fi
  done
  if [ "$ok" -eq 0 ]; then
    printf '%s\t%s\t%s\n' "$uuid_bn" "$agent_name" "$(echo $inbound_stems | tr ' ' ',')" >> "$NAME_MISMATCH_FILE"
  fi
done < "$UUID_FILES_FILE"
NAME_MISMATCH=$(wc -l < "$NAME_MISMATCH_FILE" | tr -d ' ')

# I4. Shared UUIDs: a UUID receives redirects from >1 distinct stem.
awk -F'\t' '{ stems[$4] = stems[$4] $2 "," }
    END {
      for (u in stems) {
        # count unique stems
        n = split(stems[u], arr, ",")
        delete uniq
        c = 0
        for (i=1; i<=n; i++) if (arr[i] != "" && !(arr[i] in uniq)) { uniq[arr[i]] = 1; c++ }
        if (c > 1) {
          out = ""
          for (k in uniq) out = (out == "" ? k : out "," k)
          print u "\t" out
        }
      }
    }' "$REDIRECTS_FILE" > "$SHARED_FILE"
SHARED=$(wc -l < "$SHARED_FILE" | tr -d ' ')

# I5. UUID files missing a token field.
awk -F'\t' '$3 != "true" { print $1 "\t" $2 }' "$UUID_FILES_FILE" > "$NO_TOKEN_FILE"
NO_TOKEN=$(wc -l < "$NO_TOKEN_FILE" | tr -d ' ')

VIOLATION_TOTAL=$((DANGLING + ORPHAN + NAME_MISMATCH + SHARED + NO_TOKEN))

if [ "$EMIT_JSON" = "1" ]; then
  dangling_json=$(awk -F'\t' '{printf "{\"stub\":\"%s\",\"missing_target\":\"%s\"}\n", $1, $2}' "$DANGLING_FILE" | jq -s .)
  orphan_json=$(awk -F'\t' '{printf "{\"uuid\":\"%s\",\"agent_name\":\"%s\"}\n", $1, $2}' "$ORPHAN_FILE" | jq -s .)
  mismatch_json=$(awk -F'\t' '{printf "{\"uuid\":\"%s\",\"uuid_agent_name\":\"%s\",\"inbound_stems\":\"%s\"}\n", $1, $2, $3}' "$NAME_MISMATCH_FILE" | jq -s .)
  shared_json=$(awk -F'\t' '{printf "{\"uuid\":\"%s\",\"stems\":\"%s\"}\n", $1, $2}' "$SHARED_FILE" | jq -s .)
  notoken_json=$(awk -F'\t' '{printf "{\"uuid\":\"%s\",\"agent_name\":\"%s\"}\n", $1, $2}' "$NO_TOKEN_FILE" | jq -s .)

  jq -n \
    --arg base "$BASE_PATH" \
    --argjson total_uuid "$TOTAL_UUID" \
    --argjson total_redirects "$TOTAL_REDIRECTS" \
    --argjson v_dangling "$DANGLING" \
    --argjson v_orphan "$ORPHAN" \
    --argjson v_mismatch "$NAME_MISMATCH" \
    --argjson v_shared "$SHARED" \
    --argjson v_notoken "$NO_TOKEN" \
    --argjson dangling "$dangling_json" \
    --argjson orphan "$orphan_json" \
    --argjson mismatch "$mismatch_json" \
    --argjson shared "$shared_json" \
    --argjson notoken "$notoken_json" \
    '{
      base_path: $base,
      total_uuid_files: $total_uuid,
      total_redirect_stubs: $total_redirects,
      violations: {
        dangling_redirects: { count: $v_dangling, items: $dangling },
        orphan_uuids:       { count: $v_orphan,   items: $orphan },
        name_mismatches:    { count: $v_mismatch, items: $mismatch },
        shared_uuids:       { count: $v_shared,   items: $shared },
        missing_token:      { count: $v_notoken,  items: $notoken }
      }
    }'
else
  printf '\n=== Keeper credential UUID layout audit ===\n'
  printf 'Base path             : %s\n' "$BASE_PATH"
  printf 'UUID-shaped files     : %d\n' "$TOTAL_UUID"
  printf 'Redirect stubs        : %d\n' "$TOTAL_REDIRECTS"
  printf 'Total invariant misses: %d\n\n' "$VIOLATION_TOTAL"

  if [ "$DANGLING" -gt 0 ]; then
    printf 'I1 — Dangling redirects (%d): stub points at a UUID that is not on disk.\n' "$DANGLING"
    while IFS=$'\t' read -r stub target; do
      printf '  - %s.json -> %s.json (missing)\n' "$stub" "$target"
    done < "$DANGLING_FILE"
    printf '  Triage: stub is unusable; either restore the UUID file from backup or move the stub to .retired/.\n\n'
  fi

  if [ "$ORPHAN" -gt 0 ]; then
    printf 'I2 — Orphan UUID files (%d): UUID file exists but no name stub redirects to it.\n' "$ORPHAN"
    while IFS=$'\t' read -r uuid agent_name; do
      printf '  - %s.json (agent_name=%s)\n' "$uuid" "$agent_name"
    done < "$ORPHAN_FILE"
    printf '  Triage: likely pre-#9737 leftover. Verify no live keeper presents this token; if confirmed safe, archive to .retired/.\n\n'
  fi

  if [ "$NAME_MISMATCH" -gt 0 ]; then
    printf 'I3 — agent_name mismatches (%d): UUID file declares an agent_name not matching any inbound stem.\n' "$NAME_MISMATCH"
    while IFS=$'\t' read -r uuid an stems; do
      printf '  - %s.json: agent_name=%s, inbound stems=[%s]\n' "$uuid" "$an" "$stems"
    done < "$NAME_MISMATCH_FILE"
    printf '  Triage: indicates a renamed keeper or a wrong redirect; check git history of the stubs.\n\n'
  fi

  if [ "$SHARED" -gt 0 ]; then
    printf 'I4 — Shared UUIDs (%d): a single UUID receives redirects from multiple distinct stems.\n' "$SHARED"
    while IFS=$'\t' read -r uuid stems; do
      printf '  - %s.json shared by stems: [%s]\n' "$uuid" "$stems"
    done < "$SHARED_FILE"
    printf '  Triage: security boundary anomaly. Identify intent; an unintended share lets one keeper authenticate as another.\n\n'
  fi

  if [ "$NO_TOKEN" -gt 0 ]; then
    printf 'I5 — UUID files missing a token (%d): Phase 3 contract violation.\n' "$NO_TOKEN"
    while IFS=$'\t' read -r uuid an; do
      printf '  - %s.json (agent_name=%s)\n' "$uuid" "$an"
    done < "$NO_TOKEN_FILE"
    printf '  Triage: the next ensure_keeper_credential call should populate; if it persists, the file may be a non-Phase-3 stub variant.\n\n'
  fi

  if [ "$VIOLATION_TOTAL" -eq 0 ]; then
    printf 'No UUID-layer integrity violations detected.\n\n'
  fi
fi

if [ "$VIOLATION_TOTAL" -gt 0 ]; then
  exit 1
fi
exit 0
