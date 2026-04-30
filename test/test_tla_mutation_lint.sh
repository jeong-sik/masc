#!/usr/bin/env bash
# Regression test for scripts/tla-mutation-lint.sh.
#
# Builds a synthetic lib/keeper/ tree under a temp dir, runs the
# detector via the TLA_LINT_KEEPER_DIR override, and asserts the
# violation count + the escape-hatch behavior.
#
# Run: bash test/test_tla_mutation_lint.sh
# Exit: 0 = all assertions pass, 1 = a case failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DETECTOR="${REPO_ROOT}/scripts/tla-mutation-lint.sh"

[ -x "$DETECTOR" ] || { echo "FAIL: detector not executable: $DETECTOR" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

mkdir -p "$TMP/lib/keeper"

# Fixture: 4 mutations, 2 masked by escape hatch.
cat > "$TMP/lib/keeper/test_fixture.ml" <<'OCAML'
(* Synthetic test fixture for tla-mutation-lint *)

let counter = ref 0

let unmasked_ref () =
  counter := !counter + 1

let masked_ref () =
  (* tla-lint: allow-mutation: heartbeat counter *)
  counter := !counter + 1

let masked_atomic () =
  let a = Atomic.make 0 in
  (* tla-lint: allow-mutation: prom counter *)
  Atomic.set a 1;
  ignore a

let unmasked_atomic () =
  let a = Atomic.make 0 in
  Atomic.set a 1;
  ignore a
OCAML

# Case 1: detector reports the right total (2 unmasked).
got="$(TLA_LINT_KEEPER_DIR="$TMP/lib/keeper" bash "$DETECTOR" --count)"
if [ "$got" != "2" ]; then
  echo "FAIL case 1: expected 2 unmasked mutations, got $got" >&2
  TLA_LINT_KEEPER_DIR="$TMP/lib/keeper" bash "$DETECTOR" >&2 || true
  exit 1
fi
echo "ok case 1 — detector counted 2 unmasked mutations (fixture has 4 total)"

# Case 2: zero-mutation fixture (a constant declaration only).
echo "let const_only = 42" > "$TMP/lib/keeper/test_fixture.ml"
got="$(TLA_LINT_KEEPER_DIR="$TMP/lib/keeper" bash "$DETECTOR" --count)"
if [ "$got" != "0" ]; then
  echo "FAIL case 2: expected 0 mutations, got $got" >&2
  exit 1
fi
echo "ok case 2 — detector returns 0 on a mutation-free fixture"

# Case 3: comment lines containing := are not mistaken for mutations.
cat > "$TMP/lib/keeper/test_fixture.ml" <<'OCAML'
(* The operator := is OCaml's ref assignment. *)
(* In TLA+ a primed assignment is x' = X, not x := X. *)
let only_comments = ()
OCAML
got="$(TLA_LINT_KEEPER_DIR="$TMP/lib/keeper" bash "$DETECTOR" --count)"
if [ "$got" != "0" ]; then
  echo "FAIL case 3: comment-only file should be 0, got $got" >&2
  TLA_LINT_KEEPER_DIR="$TMP/lib/keeper" bash "$DETECTOR" >&2 || true
  exit 1
fi
echo "ok case 3 — comment lines containing := are not flagged"

echo ""
echo "[tla-mutation-lint test] PASS — 3/3 cases"
