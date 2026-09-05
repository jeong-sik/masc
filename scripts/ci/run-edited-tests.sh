#!/usr/bin/env bash
# Link and run the test executables whose source this PR edits, and nothing
# else. RFC-0428.
#
# Report-only by its caller: the workflow step carries continue-on-error, so
# a red suite is a line on the PR page and not a gate. main's red count is
# not known yet, and gating on an unknown number blocks PRs that changed
# nothing to do with it.
#
# The changed-file list comes from the pull request API rather than from
# git. This job checks out at depth 1 plus tags, so a three-dot diff has no
# merge base to stand on and would answer with the whole tree -- which here
# means "link all 344 suites", the exact cost this design exists to avoid.
set -euo pipefail

pr_number="${1:?usage: run-edited-tests.sh <pr-number>}"

# A guess at a runaway list rather than a budget. Twelve suites is far past
# what a PR normally edits; past it, the list is more likely wrong than the
# PR is large, and running it would spend the job's remaining minutes proving
# that.
max_suites=12

changed=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/files" \
  --paginate --jq '.[] | select(.status != "removed") | .filename')

suites=$(printf '%s\n' "${changed}" \
  | grep -E '^test/test_[a-z0-9_]+\.ml$' \
  | sed -e 's|^test/||' -e 's|\.ml$||' \
  | sort -u || true)

if [ -z "${suites}" ]; then
  echo "no test/test_*.ml in this pull request; nothing to run"
  exit 0
fi

count=$(printf '%s\n' "${suites}" | wc -l | tr -d ' ')
echo "test sources this pull request edits: ${count}"
printf '%s\n' "${suites}" | sed 's/^/  /'

if [ "${count}" -gt "${max_suites}" ]; then
  echo "more than ${max_suites} suites; not running any of them"
  exit 0
fi

# No check that a stanza file exists first. Most suites are named in a
# per-file test/stanzas/<name>.inc, but some are names inside a (tests ...)
# group in test/dune -- test_tui_decode is one -- and looking for the .inc
# skipped those without saying so. dune is the authority on whether a target
# is buildable, and it says so out loud.
failed=""
while IFS= read -r suite; do
  [ -n "${suite}" ] || continue
  echo "== ${suite}"
  if ! dune build "test/${suite}.exe"; then
    failed="${failed}${suite} (link)\n"
    continue
  fi
  if ! "./_build/default/test/${suite}.exe"; then
    failed="${failed}${suite} (run)\n"
  fi
done <<EOF
${suites}
EOF

if [ -z "${failed}" ]; then
  echo "every edited suite linked and passed"
  exit 0
fi

echo "suites that did not pass:"
printf '  %b' "${failed}"
exit 1
