#!/usr/bin/env bash
# Self-test for wire-field-removal-schema-gate.sh.
#
# Pins the gate's full behavior on a synthetic git tree:
#   A. wire-label removal with no compat story   -> exit 1, incidents named
#   B. removal + new strip script                -> OK
#   C. comment-only ADDITION (prose mention)     -> silent OK
#   D. removal + version sentinel bump           -> OK
#   E. removal + 'schema-compat:' commit note    -> OK
#   F. wrong ROOT (non-masc tree)                -> exit 2, loud failure
#   H. removal + vNN MENTION only, no real bump  -> exit 1
#   I. registry marker row deleted in keeper_event_queue_schema.ml -> exit 1
#      (#35308 moved the markers into that module on 2026-09-12 while the
#      gate kept guarding only the five old addresses — silent pass then)
#   J. in-place quoted-marker bump (no -vNN.json token) credits a removal
#   K. non-field_* let-string row deleted in a legacy protected module -> 1
# The F case exists because the ROOT formula was once observed to land on
# the keeper playground root, where the gate would silently report
# "no protected module changed" while scanning nothing.
# The H case exists because the bump test once accepted any -vNN.json(l)
# substring on an added line (task-1545, F4).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wire-gate-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/lib/keeper" "$TMP/lib/keeper_runtime" "$TMP/scripts"
cp "${SCRIPT_DIR}/wire-field-removal-schema-gate.sh" "$TMP/scripts/"

cat >"$TMP/lib/keeper/keeper_memory_os_current.ml" <<'EOF'
let field_source = "source"
let field_facts = "facts"
let field_change = "change"
let exact_object_fields required fields = required
EOF
cat >"$TMP/lib/keeper_runtime/keeper_event_queue_schema.ml" <<'EOF'
(* generation registry: single source of truth (#35308) *)
let state = "keeper.event_queue.state.v19"
let transition_wal = "masc.keeper_event_queue.transition.v9"
let snapshot_filename = "event-queue-v19.json"
EOF
cat >"$TMP/lib/keeper_runtime/keeper_event_queue_persistence.ml" <<'EOF'
let snapshot_filename = "event-queue-v19.json"
EOF

cd "$TMP"
git init -q .
git add -A
git -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -qm base --no-verify

commit() { git add -A; git -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -qm "$1" --no-verify; }
run_gate() { bash scripts/wire-field-removal-schema-gate.sh "$1" >/tmp/wg-st.out 2>&1; echo $?; }

# F first: pointed at a directory that is not a git worktree -> loud exit 2.
# (env assignments before `bash` do NOT survive a command substitution with a
# relative script path unless exported; use env -h style explicit export.)
export WIRE_GATE_ROOT=/tmp/nonexistent-masc
rc="$(bash scripts/wire-field-removal-schema-gate.sh HEAD >/tmp/wg-st.out 2>&1; echo $?)"
unset WIRE_GATE_ROOT
[ "$rc" = "2" ] || { echo "self-test FAILED: wrong ROOT must exit 2, got $rc" >&2; exit 1; }

# A) label removal alone -> FAIL with incident references.
# (guard: without WIRE_GATE_ROOT set, the gate must compute the TMP root.)
export WIRE_GATE_ROOT="$PWD"
sed -i.bak '/^let field_source = "source"$/d' lib/keeper/keeper_memory_os_current.ml
rm -f lib/keeper/keeper_memory_os_current.ml.bak
commit "remove field_source"
rc="$(run_gate HEAD~1)"
[ "$rc" = "1" ] || { echo "self-test FAILED: label removal alone must exit 1, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }
grep -q "29516" /tmp/wg-st.out || { echo "self-test FAILED: incident refs missing" >&2; exit 1; }

# B) removal + new strip script -> OK.
cat >scripts/strip-old-source-key.sh <<'EOF'
#!/usr/bin/env sh
echo "strip legacy source keys"
EOF
commit "add strip script"
rc="$(run_gate HEAD~2)"
[ "$rc" = "0" ] || { echo "self-test FAILED: strip script must pass, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

# C) comment-only ADDITION -> silent OK.
printf '(* historical: let field_ghost = "ghost" was never here *)\n' >>lib/keeper/keeper_memory_os_current.ml
commit "comment only addition"
rc="$(run_gate HEAD~1)"
[ "$rc" = "0" ] || { echo "self-test FAILED: comment-only addition must stay silent, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

# D) removal + version sentinel bump -> OK.
sed -i.bak '/^let field_facts = "facts"$/d' lib/keeper/keeper_memory_os_current.ml
rm -f lib/keeper/keeper_memory_os_current.ml.bak
sed -i.bak 's/event-queue-v19\.json/event-queue-v20.json/' lib/keeper_runtime/keeper_event_queue_persistence.ml
rm -f lib/keeper_runtime/keeper_event_queue_persistence.ml.bak
commit "remove facts row + bump v20"
rc="$(run_gate HEAD~1)"
[ "$rc" = "0" ] || { echo "self-test FAILED: version bump must pass, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

# H) removal + a MENTION of a version sentinel on an added line -> FAIL.
#    A bump must be a MOVE: an old version leaving a `-` line and a
#    different version arriving on a `+` line. Prose that merely names
#    event-queue-v19.json is not a bump (task-1545, F4).
printf 'let field_history = "history"\n' >>lib/keeper/keeper_memory_os_current.ml
commit "add history row"
sed -i.bak '/^let field_history = "history"$/d' lib/keeper/keeper_memory_os_current.ml
rm -f lib/keeper/keeper_memory_os_current.ml.bak
cat >>lib/keeper_runtime/keeper_event_queue_persistence.ml <<'EOF'
(* prose: earlier snapshots lived in event-queue-v19.json (task-598) *)
EOF
commit "remove history row + only mention v19"
rc="$(run_gate HEAD~1)"
[ "$rc" = "1" ] || { echo "self-test FAILED: sentinel mention must NOT count as a bump, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

# E) removal + schema-compat commit note -> OK.
sed -i.bak '/^let field_change = "change"$/d' lib/keeper/keeper_memory_os_current.ml
rm -f lib/keeper/keeper_memory_os_current.ml.bak
commit "remove change row
schema-compat: rg -c 'field_change' on live memory snapshots == 0 (swept)"
rc="$(run_gate HEAD~1)"
[ "$rc" = "0" ] || { echo "self-test FAILED: schema-compat note must pass, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

# I) registry marker row deleted in keeper_event_queue_schema.ml -> FAIL.
#    #35308 moved the generation markers into this module on 2026-09-12;
#    while the gate kept guarding only the five old addresses, this diff
#    exited 0 silently (task-853).
sed -i.bak '/^let state = /d' lib/keeper_runtime/keeper_event_queue_schema.ml
rm -f lib/keeper_runtime/keeper_event_queue_schema.ml.bak
commit "remove state marker row"
rc="$(run_gate HEAD~1)"
[ "$rc" = "1" ] || { echo "self-test FAILED: registry marker removal must exit 1, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

# J) in-place quoted-marker generation move must CREDIT the removal: the
#    transition.v9 row leaves and transition.v10 arrives on a `+` line. No
#    -vNN.json token moves, so the filename path of version_bump sees
#    nothing; the quoted-marker family rule carries the OK (task-853).
sed -i.bak 's/transition\.v9/transition.v10/' lib/keeper_runtime/keeper_event_queue_schema.ml
rm -f lib/keeper_runtime/keeper_event_queue_schema.ml.bak
commit "bump transition marker v9->v10 in place"
rc="$(run_gate HEAD~1)"
[ "$rc" = "0" ] || { echo "self-test FAILED: quoted-marker bump must pass, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

# K) a deleted let-string row whose name is neither field_* nor a paren
#    label row must still fire in a legacy protected module: the let TARGET
#    NAME is not the signal (task-853).
printf 'let marker_cache = "memory-os.v3"\n' >>lib/keeper/keeper_memory_os_current.ml
commit "add marker_cache row"
sed -i.bak '/^let marker_cache = /d' lib/keeper/keeper_memory_os_current.ml
rm -f lib/keeper/keeper_memory_os_current.ml.bak
commit "remove marker_cache row, no story"
rc="$(run_gate HEAD~1)"
[ "$rc" = "1" ] || { echo "self-test FAILED: non-field_* let-row removal must exit 1, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

# G) the default ROOT formula itself: invoked WITHOUT WIRE_GATE_ROOT from the
#    standard layout (script at <root>/scripts/), the gate must resolve the
#    synthetic repo root — one level up, not two. The ../.. off-by-one shipped
#    in the first revision and failed in CI with
#    "REPO_ROOT '/home/runner/work/masc' is not a git worktree" while every
#    explicit-WIRE_GATE_ROOT scenario stayed green. Guard: the synthetic tree
#    here sits at $TMP/scripts/…, so a two-level formula resolves above the
#    worktree and the gate must die loudly (exit 2), not scan nothing.
unset WIRE_GATE_ROOT
mkdir -p "$TMP/root/scripts"
cp scripts/wire-field-removal-schema-gate.sh "$TMP/root/scripts/"
git -C "$TMP/root" init -q 2>/dev/null || true
if (cd "$TMP/root" && bash scripts/wire-field-removal-schema-gate.sh HEAD >/tmp/wg-st.out 2>&1); then
  rc_ok=0
else
  rc_ok=$?
fi
[ "$rc_ok" = "0" ] || { echo "self-test FAILED: default formula must resolve the standard layout (got exit $rc_ok)" >&2; cat /tmp/wg-st.out >&2; exit 1; }
grep -q "not a git worktree\|ERROR" /tmp/wg-st.out && { echo "self-test FAILED: standard layout must not trip the worktree guard" >&2; exit 1; }

echo "wire-field-removal-schema-gate self-test: pass"
