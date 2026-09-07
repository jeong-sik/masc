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
dune_root="${repo_root}/dune"

fail() {
  echo "OCaml compile authority drift: $*" >&2
  exit 1
}


# The root dune carries the tree-wide warning mask in two (flags (:standard …))
# lists, dev and release. This used to be checked by matching the whole list as
# one literal string, which pinned the guard to a single exact spelling: adding
# -w +32 to that same list satisfied the check's stated intent and broke the
# check. Assert one flag at a time against the flag lists so another flag can be
# added without editing this script, while dropping one still fails.
#
# -w +32 (unused value declaration) is load-bearing here, not cosmetic. It was
# previously decided per library -- 84 of the 121 stanzas under lib/ opted in,
# 37 did not -- and an unreachable value in one of those 37 produced no signal
# at all. Removing it from the root returns the tree to that state silently.
#
# The filter keys on "(:standard -" rather than on any particular flag: the
# (dirs …) stanza at the top of the file also opens with (:standard, but with
# nothing after it, while every flag list continues with a flag. Keying on one
# of the required flags instead would report "0 flag lists" when that same flag
# is the one missing, which is the case this exists to diagnose.
flag_lines="$(grep -F -- '(:standard -' "${dune_root}" || true)"
flag_line_count="$(grep -c . <<<"${flag_lines}" || true)"
[ "${flag_line_count}" -eq 2 ] \
  || fail "root dune env must have exactly 2 (:standard …) flag lists (dev, release), found ${flag_line_count}"
for required_flag in '-w +32' '+69' '-warn-error +a'; do
  present="$(grep -Fc -- "${required_flag}" <<<"${flag_lines}" || true)"
  [ "${present}" -eq 2 ] \
    || fail "root dune env must set ${required_flag} in dev and release, found it in ${present} of 2"
done

echo "OCaml compile authority: PASS (root dune sets -w +32, +69 and -warn-error +a in dev and release)"
