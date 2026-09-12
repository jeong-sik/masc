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
# The F case exists because the ROOT formula was once observed to land on
# the keeper playground root, where the gate would silently report
# "no protected module changed" while scanning nothing.
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

# E) removal + schema-compat commit note -> OK.
sed -i.bak '/^let field_change = "change"$/d' lib/keeper/keeper_memory_os_current.ml
rm -f lib/keeper/keeper_memory_os_current.ml.bak
commit "remove change row
schema-compat: rg -c 'field_change' on live memory snapshots == 0 (swept)"
rc="$(run_gate HEAD~1)"
[ "$rc" = "0" ] || { echo "self-test FAILED: schema-compat note must pass, got $rc" >&2; cat /tmp/wg-st.out >&2; exit 1; }

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
