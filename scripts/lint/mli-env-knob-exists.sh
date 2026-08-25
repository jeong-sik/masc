#!/usr/bin/env bash
# An interface that names a MASC_* env var is telling a reader that setting it
# does something. That claim is only true if some code reads the name, some
# test pins its behaviour, or some script exports it.
#
# The class this closes, found by sweeping every MASC_* name in lib/**/*.mli
# against the rest of the tree:
#
#   MASC_LOCAL_LLM_ENDPOINTS      the reader takes LLM_ENDPOINTS; the MASC_
#                                 name existed nowhere, so an operator
#                                 following the interface set nothing
#   MASC_TRANSPORT_IDLE_EVICT_SEC RFC-0099 lists it under PR-5, still
#                                 unchecked; the bound is a literal default
#   MASC_DISCORD_BUILTIN          named only to say it was removed
#
# A knob exercised solely by a test still passes: MASC_FSM_GUARD_ASSERT is
# named in keeper_fsm_guard_runtime.mli to state that setting it does not
# re-enable soft mode, and test_keeper_fsm_guard_actions.ml holds that
# invariant. Documented + pinned is not the failure this looks for.
#
# Usage: mli-env-knob-exists.sh [--fail|--print|--self-test]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MODE="${1:---fail}"
case "$MODE" in
  --fail | --print | --self-test) ;;
  -h | --help)
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print|--self-test]" >&2
    exit 2
    ;;
esac

command -v rg >/dev/null 2>&1 || {
  echo "[mli-env-knob-exists] required tool missing: rg" >&2
  exit 2
}

# Names claimed by an interface, and names the tree actually exercises.
# Search roots are disjoint on suffix, so a name found only in .mli files
# cannot appear in the second list.
collect_claimed() {
  rg --no-filename --only-matching '\bMASC_[A-Z0-9_]{3,}\b' \
    --glob '*.mli' "$1/lib" 2>/dev/null | sort -u
}

# Only OCaml sources count as evidence. A shell script that exports a name
# proves nothing when no code reads it, and this file names the knobs it was
# written to catch — scanning scripts/ would let the checker whitelist its own
# findings.
collect_exercised() {
  rg --no-filename --only-matching '\bMASC_[A-Z0-9_]{3,}\b' \
    --glob '*.ml' "$1/lib" "$1/bin" "$1/test" 2>/dev/null | sort -u
}

report() {
  local tree="$1"
  comm -23 <(collect_claimed "$tree") <(collect_exercised "$tree")
}

case "$MODE" in
  --print)
    report "$ROOT"
    exit 0
    ;;
  --self-test)
    # Prove the check can fail: a scratch tree whose interface names a knob
    # nothing reads must be reported, and the same tree with a reader must not.
    scratch="$(mktemp -d -t mli-env-knob.XXXXXX)"
    trap 'rm -rf "$scratch"' EXIT
    mkdir -p "$scratch/lib" "$scratch/bin" "$scratch/test" "$scratch/scripts"
    printf '(** [MASC_SELF_TEST_PHANTOM] does nothing. *)\nval f : unit -> unit\n' \
      >"$scratch/lib/probe.mli"
    if [ "$(report "$scratch")" != "MASC_SELF_TEST_PHANTOM" ]; then
      echo "[mli-env-knob-exists] self-test: an unread knob was not reported" >&2
      exit 1
    fi
    printf 'let f () = ignore (Sys.getenv_opt "MASC_SELF_TEST_PHANTOM")\n' \
      >"$scratch/lib/probe.ml"
    if [ -n "$(report "$scratch")" ]; then
      echo "[mli-env-knob-exists] self-test: a read knob was still reported" >&2
      exit 1
    fi
    echo "[mli-env-knob-exists] self-test OK"
    exit 0
    ;;
esac

orphans="$(report "$ROOT")"
claimed_count="$(collect_claimed "$ROOT" | wc -l | tr -d ' ')"

if [ -z "$orphans" ]; then
  echo "[mli-env-knob-exists] OK: ${claimed_count} knobs named in .mli, every one exercised"
  exit 0
fi

echo "[mli-env-knob-exists] an interface names a knob nothing reads:" >&2
while IFS= read -r knob; do
  [ -n "$knob" ] || continue
  echo "  $knob" >&2
  rg --line-number --glob '*.mli' --no-heading "\b${knob}\b" "$ROOT/lib" 2>/dev/null |
    sed "s|$ROOT/|    |" >&2
done <<<"$orphans"
echo >&2
echo "Either wire the knob, or state what the code actually does." >&2
exit 1
