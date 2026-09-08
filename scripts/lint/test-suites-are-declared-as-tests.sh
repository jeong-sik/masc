#!/usr/bin/env bash
# A suite named test_* must be declared as a dune (test), not an (executable).
#
# An (executable) is linked by @check and run by nothing: dune runtest skips it,
# and scripts/ci/run-edited-tests.sh has no suite to name because it selects on
# the stanza kind. The suite compiles for as long as it exists and never asserts
# anything. test_masc_context_injector sat that way -- 259 lines over the
# context injector the keeper turn path builds every turn.
#
# scripts/ci/dune_suite_scope.py already reports this, one suite at a time, as
# "skip not declared as a test executable in its dune file". Nothing read it
# across all of them, which is why this went unseen. This is that read.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUNE_FILE="${REPO_ROOT}/test/dune"

# A scan that finds no suites at all has lost its file, not found a clean tree.
MIN_STANZAS=200

scan() {
  python3 - "$1" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
# Top-level stanzas start in column 0; a stanza runs until the next one.
stanzas = re.findall(r'\((executable|executables|test|tests)\b(.*?)(?=\n\(|\Z)', text, re.S)
total = 0
bad = []
for kind, body in stanzas:
    names = ' '.join(re.findall(r'\(names?\s+([^)]*)\)', body)).split()
    for name in names:
        total += 1
        if kind.startswith('executable') and name.startswith('test_'):
            bad.append(name)
print(total)
for name in bad:
    print(name)
PY
}

self_test() {
  local tmp rc=0 out
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat > "$tmp/clean" <<'DUNE'
(test
 (name test_alpha)
 (libraries x))

(executable
 (name tool_matrix_manifest)
 (libraries x))
DUNE
  out="$(scan "$tmp/clean")"
  if [[ "$(echo "$out" | tail -n +2)" == "" ]]; then
    echo "[PASS] pass: a (test) suite and a non-test (executable) are both fine"
  else
    echo "[FAIL] a clean dune file was reported: $out" >&2; rc=1
  fi

  cat > "$tmp/dirty" <<'DUNE'
(test
 (name test_alpha)
 (libraries x))

(executable
 (name test_beta)
 (libraries x))
DUNE
  out="$(scan "$tmp/dirty" | tail -n +2)"
  if [[ "$out" == "test_beta" ]]; then
    echo "[PASS] fire: a test_-named (executable) is reported"
  else
    echo "[FAIL] the misdeclared suite was not reported: '$out'" >&2; rc=1
  fi

  cat > "$tmp/plural" <<'DUNE'
(executables
 (names test_gamma helper_tool)
 (libraries x))
DUNE
  out="$(scan "$tmp/plural" | tail -n +2)"
  if [[ "$out" == "test_gamma" ]]; then
    echo "[PASS] fire: (executables) with several names is read name by name"
  else
    echo "[FAIL] the plural stanza was misread: '$out'" >&2; rc=1
  fi

  return "$rc"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

output="$(scan "$DUNE_FILE")"
total="$(printf '%s\n' "$output" | head -1)"
offenders="$(printf '%s\n' "$output" | tail -n +2)"

if (( total < MIN_STANZAS )); then
  echo "[suite-kind] read ${total} stanza name(s) from ${DUNE_FILE}, expected at least ${MIN_STANZAS}." >&2
  echo "The scan lost the file or its shape, rather than finding a clean tree." >&2
  exit 2
fi

if [[ -n "$offenders" ]]; then
  echo "A suite named test_* is declared as an (executable), so nothing runs it:" >&2
  printf '%s\n' "$offenders" | sed 's|^|  |' >&2
  echo >&2
  echo "Change the stanza to (test). dune runtest and the edited-tests selector" >&2
  echo "both go by the stanza kind." >&2
  exit 1
fi

echo "test suite stanzas: 0 test_-named (executable) across ${total} stanza name(s)"
