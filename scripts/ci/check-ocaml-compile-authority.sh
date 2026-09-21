#!/usr/bin/env bash
#
# The root dune's warning mask, asserted where the root dune says it is.
#
# This script used to check two things. The other one read .github/ci.yml and
# asserted a job called "Build and Test" ran
# `dune build --root . @default @check @install`, that a job called "Health"
# passed --skip-build, and that a job called "Lint" ran three named scripts
# and compiled nothing. #32511 replaced that nine-job lane with one job on
# 2026-09-02, so none of those jobs exist and every one of those assertions
# was drift against a lane that is gone -- the script has been failing since,
# unseen, because the only place naming it is a comment in the root dune.
#
# What is left is the half that still has a subject. The root dune says
# "check-ocaml-compile-authority.sh asserts both flags stay here"; this is
# that assertion, and now something runs it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "OCaml compile authority drift: $*" >&2
  exit 1
}


# The root dune carries the tree-wide warning mask in dev and release. Inspect
# Dune's effective flags rather than the source layout: whitespace, line breaks,
# or another flag in the stanza must not change this policy check.
#
# -w +32 (unused value declaration) is load-bearing here, not cosmetic. It was
# previously decided per library -- 84 of the 121 stanzas under lib/ opted in,
# 37 did not -- and an unreachable value in one of those 37 produced no signal
# at all. Removing it from the root returns the tree to that state silently.
assert_strict_root_flags() {
  local profile="$1"
  local flags="$2"
  local previous=""
  local has_warning_32=0
  local has_warning_69=0
  local has_warn_error_all=0
  local token

  while IFS= read -r token; do
    case "${previous}" in
      -w)
        [[ "${token}" == *+32* ]] && has_warning_32=1
        [[ "${token}" == *-32* ]] && has_warning_32=0
        [[ "${token}" == *+69* ]] && has_warning_69=1
        [[ "${token}" == *-69* ]] && has_warning_69=0
        ;;
      -warn-error)
        [[ "${token}" == *+a* ]] && has_warn_error_all=1
        ;;
    esac
    previous="${token}"
  done < <(tr '()' '  ' <<<"${flags}" | tr -s '[:space:]' '\n')

  [ "${has_warning_32}" -eq 1 ] \
    || fail "${profile} root flags lost warning 32: ${flags}"
  [ "${has_warning_69}" -eq 1 ] \
    || fail "${profile} root flags lost warning 69: ${flags}"
  [ "${has_warn_error_all}" -eq 1 ] \
    || fail "${profile} root flags lost -warn-error +a: ${flags}"
}

cd "${repo_root}"
for profile in dev release; do
  root_flags="$(dune printenv --profile "${profile}" . --field flags)"
  assert_strict_root_flags "${profile}" "${root_flags}"
done

echo "OCaml compile authority: PASS (effective dev and release root warnings are strict)"
