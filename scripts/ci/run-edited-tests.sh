#!/usr/bin/env bash
# Run the test suites whose source this pull request edits, and nothing else.
# RFC-0428.
#
# Report-only by its caller. main's red count is not known yet, and gating on
# an unknown number blocks pull requests that changed nothing to do with it.
#
# What this does NOT do is run a suite the way `dune test` runs it. A stanza
# can carry deps only the runtest action materialises, an (action (setenv ...))
# only dune applies, or an enabled_if meaning there is no executable at all;
# executing the binary by hand then fails for reasons that have nothing to do
# with the change under test -- test_server_runtime_bootstrap fails with the
# literal words "run the test via Dune". dune has no per-suite runtest alias to
# ask for instead, so dune_suite_scope.py reads the declaring stanza and this
# runs only the suites where a direct run is faithful. The rest are named and
# skipped in the log rather than passed over quietly.
set -euo pipefail

pr_number="${1:?usage: run-edited-tests.sh <pr-number>}"
repo="${MASC_TARGET_REPO:-${GITHUB_REPOSITORY}}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scope_tool="${repo_root}/scripts/ci/dune_suite_scope.py"

# A guess at a runaway list rather than a budget. Twelve suites is far past
# what a pull request normally edits; past it the list is more likely wrong
# than the pull request is large.
max_suites=12

# Per suite, so one hang costs this step and not the job. The job's own
# timeout-minutes cancels everything and reports the job failed whatever a
# step's continue-on-error says.
per_suite_timeout=300

# The changed-file list comes from the pull request API, not from git. This
# job checks out at depth 1 plus tags, so a three-dot diff has no merge base
# and would answer with the whole tree.
changed=$(gh api "repos/${repo}/pulls/${pr_number}/files" \
  --paginate --jq '.[] | select(.status != "removed") | .filename')

# Guard grep's own no-match exit rather than the pipeline's: under pipefail a
# bare `|| true` at the end also swallows a sed or sort that failed, and an
# empty list then reads the same as "this pull request edits no tests".
sources=$( { printf '%s\n' "${changed}" \
  | grep -E '(^|/)test/test_[a-z0-9_]+\.ml$' || [ $? -eq 1 ]; } | sort -u)

# A guard can protect an input that is not itself a test, and then no pull
# request that breaks it ever edits it.
# test_managed_assets_sync_from_binary runs the real sync over the real
# embedded set, so a config/ asset added without its line in that domain's
# managed-assets.json fails there rather than at the next boot -- which is
# what its header says it is for. But a pull request that adds
# config/tools/foo.toml edits no test/*.ml, so the selector above picks
# nothing and the guard never runs.
#
# Measured 2026-09-06: #33472 added keeper_lane_status.toml and #33639 added
# the three masc_file_* tools. Neither ran the guard, neither updated the
# manifest, and every boot since printed the half-built-binary WARN with
# those four stranded out of the runtime directory.
#
# So map the guarded input back to its guard.
assets=$( { printf '%s\n' "${changed}" \
  | grep -E '^config/(prompts|tools|mcp)/' || [ $? -eq 1 ]; } | head -1)
if [ -n "${assets}" ]; then
  echo "this pull request changes managed config assets; adding their guard"
  sources=$(printf '%s\n%s\n' "${sources}" \
    "test/test_managed_assets_sync_from_binary.ml" \
    | grep -v '^[[:space:]]*$' | sort -u)
fi

if [ -z "${sources}" ]; then
  echo "no test source in this pull request; nothing to run"
  exit 0
fi

count=$(printf '%s\n' "${sources}" | wc -l | tr -d ' ')
echo "test sources this pull request edits: ${count}"
printf '%s\n' "${sources}" | sed 's/^/  /'

if [ "${count}" -gt "${max_suites}" ]; then
  echo "NOT RUN: more than ${max_suites} suites, which reads as a wrong list"
  exit 0
fi

ran=0
skipped=0
failed=""
while IFS= read -r source; do
  [ -n "${source}" ] || continue
  dir=$(dirname "${source}")
  name=$(basename "${source}" .ml)
  verdict=$(python3 "${scope_tool}" "${dir}" "${name}")
  case "${verdict}" in
    run) ;;
    *)
      echo "-- ${dir}/${name}: ${verdict#skip }"
      skipped=$((skipped + 1))
      continue
      ;;
  esac
  echo "== ${dir}/${name}"
  if ! dune build "${dir}/${name}.exe" < /dev/null; then
    failed="${failed}${dir}/${name} (build)\n"
    continue
  fi
  # dune runs a suite from inside its own build directory, and suites read
  # relative paths from there. DUNE_SOURCEROOT is what the ones that want the
  # checkout read; without it they fall back to the cwd, which from here would
  # be the wrong tree.
  binary="${repo_root}/_build/default/${dir}/${name}.exe"
  if [ ! -x "${binary}" ]; then
    # The build reported success and the binary is not where dune puts it,
    # which is a different thing from a suite that failed. Saying so keeps
    # the two apart in the log.
    failed="${failed}${dir}/${name} (built, but no binary at ${binary})\n"
    continue
  fi
  if ! ( cd "${repo_root}/_build/default/${dir}" \
         && DUNE_SOURCEROOT="${repo_root}" \
            timeout "${per_suite_timeout}" "./${name}.exe" < /dev/null ); then
    failed="${failed}${dir}/${name} (run)\n"
    continue
  fi
  ran=$((ran + 1))
done <<EOF
${sources}
EOF

echo "ran ${ran}, skipped ${skipped}"

if [ -z "${failed}" ]; then
  exit 0
fi

echo "suites that did not pass:"
printf '  %b' "${failed}"
exit 1
