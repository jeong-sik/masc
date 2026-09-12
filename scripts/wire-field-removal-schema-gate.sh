#!/usr/bin/env bash
# wire-field-removal-schema-gate.sh — a removed wire field or variant in a
# persistence schema must not deploy without a compat story (#29516 #29601
# #29666).
#
# Why this gate exists: on 2026-08-22/23 three incidents in ~24h froze the
# whole keeper fleet. Each time a PR deleted a constructor or wire field from
# a strict JSONL/snapshot decoder while live stores still carried rows that
# used it, and the snapshot loader then rejected the WHOLE store:
#   - #29490 removed Goal_reconciliation_ready (+goal_assigned decoder) from
#     Keeper_event_queue.stimulus_payload → event-queue-v15 history rows
#     failed → 4 keepers could not turn for 3.5h (#29516)
#   - #29590 removed owner_nonce from the transition schema, left the queue
#     version at v16 → 7/7 keepers down at deploy (#29601)
#   - #29590 also removed source.generation while the memory-os decoder used
#     exact_object_fields (exact arity) → 12/12 memory snapshots rejected,
#     531 recall misses, plus the same class in TurnRecord (72 sweeps
#     skipped) (#29666)
# Common root: "필드를 빼는 PR이 저장소를 어떻게 처리했는지 아무도 안 묻는다".
# The rule #29553 already stated ("removed variants ride the schema
# version") becomes a gate here — shared across stores, not per-store
# (#29666: a per-store answer guarantees a fourth incident).
#
# How the gate works (diff-driven, house pattern of
# check-boundary-guard-mli-pairs.sh):
#   1. If the PR diff touches a protected persistence schema module (see
#      PROTECTED below) with a REMOVED variant constructor (`| Foo ->` line
#      deleted) or a REMOVED wire string label (`- let field_x = "x"` /
#      deleted `"x",` row in an encoder/decoder), the gate fires.
#   2. It passes only if the same diff ALSO carries one of:
#      a. a version bump in a protected module (e.g. event-queue-v19 → v20),
#      b. a new migration/strip/maintenance script for the store
#         (scripts/**strip*.sh|.py / migrate / fix),
#      c. an explicit `schema-compat:` justification line in the diff message
#         or the changed modules (live-store sweep result: e.g. rg -c = 0,
#         or rows are write-once evidence that no loader reads back).
#
# CI usage:   env BASE_REF=... run-lint-suite.sh blocking-pr BASE
# Local:      scripts/wire-field-removal-schema-gate.sh [BASE_REF]
#
# Bash-3.2 compatible, read-only on the worktree.

set -eu

REPO_ROOT="${WIRE_GATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# The gate lives at <root>/scripts/, so ONE level up is the repo root. An
# earlier revision copied the two-level "../.." formula from the
# scripts/lint/ ratchet and landed one directory too high — locally on the
# keeper playground root, and on GitHub Actions at /home/runner/work/masc
# (checkout is /home/runner/work/masc/masc). The worktree guard below is
# what turned that silent mis-scan into a loud failure both times; keep it.
if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "WIRE-GATE ERROR: REPO_ROOT '${REPO_ROOT}' is not a git worktree (set WIRE_GATE_ROOT explicitly)" >&2
  exit 2
fi
BASE_REF="${1:-${BASE_REF:-origin/main}}"

# Persistence modules whose wire shapes are load-bearing for live stores.
PROTECTED="
lib/keeper_runtime/keeper_event_queue_state.ml
lib/keeper_runtime/keeper_event_queue_persistence.ml
lib/keeper/keeper_memory_os_current.ml
lib/types/turn_record.ml
lib/keeper/keeper_meta_contract.ml
"

if ! git -C "${REPO_ROOT}" rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
  if git -C "${REPO_ROOT}" rev-parse --verify --quiet HEAD~1 >/dev/null; then
    echo "WIRE-GATE: BASE_REF '${BASE_REF}' not found, falling back to HEAD~1"
    BASE_REF="HEAD~1"
  else
    echo "WIRE-GATE: skipped — cannot resolve BASE_REF '${BASE_REF}'"
    exit 0
  fi
fi

DIFF_RANGE="${BASE_REF}...HEAD"
if git -C "${REPO_ROOT}" diff --quiet "${DIFF_RANGE}" 2>/dev/null; then
  echo "WIRE-GATE: no diff vs ${BASE_REF}"
  exit 0
fi

# Escape hatch for merges of already-gated series and explicit compat notes.
if git -C "${REPO_ROOT}" log --format=%B "${DIFF_RANGE}" 2>/dev/null \
    | grep -qi '^schema-compat:'; then
  echo "WIRE-GATE: schema-compat justification present in commit message(s)"
  exit 0
fi

diff_changed() { # files changed by the diff
  git -C "${REPO_ROOT}" diff --name-only "${DIFF_RANGE}" -- $PROTECTED 2>/dev/null || true
}

diff_has() { # removed-line regex, added-line regex, both whole-diff
  git -C "${REPO_ROOT}" diff -U0 "${DIFF_RANGE}" -- $PROTECTED 2>/dev/null \
    | grep -Eq "$1"
}

removed_variant() {
  # A deleted OCaml variant constructor line: `-  | Foo` (allow trailing
  # payload), excluding pure comment deletions.
  diff_has '^-[[:space:]]*\|[[:space:]]*[A-Z][A-Za-z0-9_]*'
}

removed_wire_label() {
  # A deleted wire-key definition or row: `- let field_x = "x"` or a deleted
  # `("x", ...)` / `| "x" ->` / `;"x"` label row.
  diff_has '^-[[:space:]]*(let[[:space:]]+field_[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*"|.*\(\")[a-z_][a-z0-9_]*(\".*|.*\|[[:space:]]*\"[a-z_][a-z0-9_]*\")'
}

version_bump() {
  # The vNN sentinel moved: event-queue-v19.json → v20 etc.
  git -C "${REPO_ROOT}" diff -U0 "${DIFF_RANGE}" -- $PROTECTED 2>/dev/null \
    | grep -E '^\+.*-(v[0-9]+)\.(json|jsonl)' -o | grep -vq '^$'
}

strip_or_migrate_added() {
  git -C "${REPO_ROOT}" diff --name-only --diff-filter=A "${DIFF_RANGE}" -- \
    'scripts/**' 2>/dev/null | grep -Eiq '(strip|migrate|cleanup|fix)-.*\.(sh|py)$'
}

compat_note_added() {
  git -C "${REPO_ROOT}" diff "${DIFF_RANGE}" -- $PROTECTED 2>/dev/null \
    | grep -Eiq '^\+.*schema-compat:'
}

fired=0
changed="$(diff_changed)"
if [ -z "${changed}" ]; then
  echo "WIRE-GATE: no protected persistence module changed vs ${BASE_REF}"
  exit 0
fi

if removed_variant || removed_wire_label; then
  fired=1
  if version_bump; then
    echo "WIRE-GATE: OK — version bump accompanies the removal"
    fired=0
  elif strip_or_migrate_added; then
    echo "WIRE-GATE: OK — store strip/migration script accompanies the removal"
    fired=0
  elif compat_note_added; then
    echo "WIRE-GATE: OK — schema-compat: note accompanies the removal"
    fired=0
  else
    echo "WIRE-GATE FAIL: wire field/variant removed from a persistence schema without a compat story" >&2
    echo "  changed protected modules:" >&2
    printf '    %s\n' ${changed} >&2
    cat >&2 <<'FIX'
  The fleet has been frozen three times in one day by exactly this shape
  (#29516, #29601, #29666): a strict decoder stopped accepting rows that
  live stores still contain. Do one of:
    a. bump the store version sentinel (e.g. event-queue-v19 -> v20) so the
       old file is treated as a foreign generation, not as poison;
    b. add a strip/migration script under scripts/ for the live stores;
    c. prove the live store is clean and say so: a line starting with
       'schema-compat:' in the commit message or the changed module
       (e.g. schema-compat: rg -c 'owner_nonce' on live stores == 0).
  References: #29553 (rule), #29516/#29601/#29666 (incidents).
FIX
    exit 1
  fi
fi

echo "WIRE-GATE: ${fired} violations"
