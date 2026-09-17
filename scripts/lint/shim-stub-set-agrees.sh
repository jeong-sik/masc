#!/usr/bin/env bash
# The shim's C stubs named by its library stanzas must be the .c files the
# static build copies.
#
# masc-exec-shim is built twice from the same sources: by dune in the repo and
# by scripts/build-shim-static.sh in a scratch project. Both builds include
# the one stanza file lib/exec_shim/shim_libraries.inc, so they name the same
# stubs. What can still drift is the source list the static build copies: a
# .c file named by a stanza but not copied does not reach the scratch project
# at all; a .c copied but named by no stanza is dead weight that a reader will
# take for a live stub.
#
# Usage: shim-stub-set-agrees.sh [--fail|--print|--self-test]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="scripts/build-shim-static.sh"
LIBRARY_STANZAS="lib/exec_shim/shim_libraries.inc"

# The words of the (names ...) field inside the (foreign_stubs ...) form of
# whichever text arrives on stdin, one per line, sorted.
stub_names_of_stdin() {
  awk '
    /\(foreign_stubs/ { in_stubs = 1 }
    in_stubs && /\(names/ {
      line = $0
      sub(/.*\(names[[:space:]]*/, "", line)
      sub(/\).*/, "", line)
      n = split(line, words, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (words[i] != "") print words[i]
      in_stubs = 0
    }
  ' | sort -u
}

repo_stubs() {
  stub_names_of_stdin < "${ROOT}/${LIBRARY_STANZAS}"
}

copied_stubs() {
  bash "${ROOT}/${BUILD_SCRIPT}" --print-sources \
    | sed -n 's#.*/\([^/]*\)\.c$#\1#p' \
    | sort -u
}

report() {
  local repo copied status=0
  repo="$(repo_stubs)"
  copied="$(copied_stubs)"

  if [ -z "${repo}" ]; then
    echo "[shim-stub-set] no (foreign_stubs (names ...)) found in ${LIBRARY_STANZAS}" >&2
    return 1
  fi

  local only_copied
  only_copied="$(comm -3 <(printf '%s\n' "${repo}") <(printf '%s\n' "${copied}"))"

  if [ -n "${only_copied}" ]; then
    echo "[shim-stub-set] the stub set and the copied .c files disagree:" >&2
    printf '  %s\n' ${only_copied} >&2
    status=1
  fi
  if [ "${status}" -eq 0 ]; then
    echo "[shim-stub-set] $(printf '%s\n' "${repo}" | wc -l | tr -d ' ') stub(s) agree with the copied sources"
  fi
  return "${status}"
}

self_test() {
  # A stanza whose (names ...) spans the line the way both real ones do, and
  # one that adds a stub, so the extractor is exercised on the shape it
  # actually meets rather than on a single word.
  local one two
  one="$(printf '(library\n (foreign_stubs\n  (language c)\n  (names prctl_stub observe_stub)))\n' \
    | stub_names_of_stdin | tr '\n' ' ')"
  if [ "${one}" != "observe_stub prctl_stub " ]; then
    echo "[shim-stub-set] self-test: two-stub stanza read as '${one}'" >&2
    return 1
  fi
  two="$(printf '(foreign_stubs (language c) (names only_one))\n' \
    | stub_names_of_stdin | tr '\n' ' ')"
  if [ "${two}" != "only_one " ]; then
    echo "[shim-stub-set] self-test: single-line stanza read as '${two}'" >&2
    return 1
  fi
  # The extractor must not read a (names ...) that belongs to something else.
  local three
  three="$(printf '(library\n (name exec_shim)\n (modules exec_shim))\n' \
    | stub_names_of_stdin | tr '\n' ' ')"
  if [ -n "${three}" ]; then
    echo "[shim-stub-set] self-test: a stanza with no stubs read as '${three}'" >&2
    return 1
  fi
  echo "[shim-stub-set] self-test passed"
}

case "${1:---fail}" in
  --print)
    echo "stanzas: $(repo_stubs | tr '\n' ' ')"
    echo "copied:  $(copied_stubs | tr '\n' ' ')"
    ;;
  --fail) report ;;
  --self-test) self_test ;;
  *)
    echo "Usage: $0 [--fail|--print|--self-test]" >&2
    exit 2
    ;;
esac
