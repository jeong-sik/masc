#!/usr/bin/env bash
# The three places that name the shim's C stubs must name the same ones.
#
# masc-exec-shim is built twice from the same sources: by dune in the repo
# (lib/exec_shim/dune) and by scripts/build-shim-static.sh, which copies the
# sources into a scratch project and writes that project's dune itself. A
# stub added to one and not the other builds here and fails to link there,
# or worse links there against a stale copy.
#
# The third list is the source list build-shim-static.sh copies. A .c file
# named by a dune stanza but not copied does not reach the scratch project
# at all; a .c copied but named by neither stanza is dead weight that a
# reader will take for a live stub.
#
# Usage: shim-stub-set-agrees.sh [--fail|--print|--self-test]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="scripts/build-shim-static.sh"
LIBRARY_DUNE="lib/exec_shim/dune"

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
  stub_names_of_stdin < "${ROOT}/${LIBRARY_DUNE}"
}

# The scratch project's dune is a heredoc inside the build script, so it is
# read from the script's text rather than by running it: running it needs a
# docker daemon, and this guard answers without one.
scratch_stubs() {
  stub_names_of_stdin < "${ROOT}/${BUILD_SCRIPT}"
}

copied_stubs() {
  bash "${ROOT}/${BUILD_SCRIPT}" --print-sources \
    | sed -n 's#.*/\([^/]*\)\.c$#\1#p' \
    | sort -u
}

report() {
  local repo scratch copied status=0
  repo="$(repo_stubs)"
  scratch="$(scratch_stubs)"
  copied="$(copied_stubs)"

  if [ -z "${repo}" ]; then
    echo "[shim-stub-set] no (foreign_stubs (names ...)) found in ${LIBRARY_DUNE}" >&2
    return 1
  fi

  local only_repo only_scratch only_copied
  only_repo="$(comm -23 <(printf '%s\n' "${repo}") <(printf '%s\n' "${scratch}"))"
  only_scratch="$(comm -13 <(printf '%s\n' "${repo}") <(printf '%s\n' "${scratch}"))"
  only_copied="$(comm -3 <(printf '%s\n' "${repo}") <(printf '%s\n' "${copied}"))"

  if [ -n "${only_repo}" ]; then
    echo "[shim-stub-set] named by ${LIBRARY_DUNE} but not by the scratch project:" >&2
    printf '  %s\n' ${only_repo} >&2
    status=1
  fi
  if [ -n "${only_scratch}" ]; then
    echo "[shim-stub-set] named by the scratch project but not by ${LIBRARY_DUNE}:" >&2
    printf '  %s\n' ${only_scratch} >&2
    status=1
  fi
  if [ -n "${only_copied}" ]; then
    echo "[shim-stub-set] the stub set and the copied .c files disagree:" >&2
    printf '  %s\n' ${only_copied} >&2
    status=1
  fi
  if [ "${status}" -eq 0 ]; then
    echo "[shim-stub-set] $(printf '%s\n' "${repo}" | wc -l | tr -d ' ') stub(s) agree across all three lists"
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
    echo "repo:    $(repo_stubs | tr '\n' ' ')"
    echo "scratch: $(scratch_stubs | tr '\n' ' ')"
    echo "copied:  $(copied_stubs | tr '\n' ' ')"
    ;;
  --fail) report ;;
  --self-test) self_test ;;
  *)
    echo "Usage: $0 [--fail|--print|--self-test]" >&2
    exit 2
    ;;
esac
