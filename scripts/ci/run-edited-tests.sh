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

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

# --self-test drives select_sources() over fixtures and never reaches the
# API, so it takes neither a pull-request number nor a repository.
self_test_only=false
[ "${1:-}" = "--self-test" ] && self_test_only=true

if [ "${self_test_only}" = false ]; then
  pr_number="${1:?usage: run-edited-tests.sh <pr-number> | --self-test}"
  repo="${MASC_TARGET_REPO:-${GITHUB_REPOSITORY}}"
fi
scope_tool="${repo_root}/scripts/ci/dune_suite_scope.py"
stanza_reader="${repo_root}/scripts/ci/stanza_env.py"

# A guess at a runaway list rather than a budget. Twelve suites is far past
# what a pull request normally edits; past it the list is more likely wrong
# than the pull request is large.
max_suites=12

# Per suite, so one hang costs this step and not the job. The job's own
# timeout-minutes cancels everything and reports the job failed whatever a
# step's continue-on-error says.
per_suite_timeout=300

# Which suites this pull request runs, from its changed-file list in
# ${changed}. Sets ${sources} and returns 1 when there is nothing to run, so
# --self-test can exercise the same code the pull-request path does rather
# than a copy of it.
select_sources() {
  # Guard grep's own no-match exit rather than the pipeline's: under pipefail a
  # bare `|| true` at the end also swallows a sed or sort that failed, and an
  # empty list then reads the same as "this pull request edits no tests".
  sources=$( { printf '%s\n' "${changed}" \
    | grep -E '(^|/)test/test_[a-z0-9_]+\.ml$' || [ $? -eq 1 ]; } | sort -u)

  # A guard can protect an input that is not itself a test, and then no pull
  # request that breaks it ever edits it.
  # test_managed_assets_sync_from_binary runs the real sync over the real
  # embedded set, so a config/ asset the binary cannot read or place fails
  # there rather than at the next boot -- which is what its header says it is
  # for. But a pull request that adds config/tools/foo.toml edits no
  # test/*.ml, so the selector above picks nothing and the guard never runs.
  #
  # Measured 2026-09-06: #33472 added keeper_lane_status.toml and #33639 added
  # the three masc_file_* tools, and neither ran the guard. Back then the
  # guard also caught a hand-written manifest missing their lines; #31283
  # removed that manifest, and the guard still proves the assets embed and
  # sync.
  assets=$( { printf '%s\n' "${changed}" \
    | grep -E '^config/(prompts|tools|mcp)/' || [ $? -eq 1 ]; } | head -1)
  asset_guard="test/test_managed_assets_sync_from_binary.ml"

  # A source edit runs the suites named after it. Before this, only editing a
  # test picked one, so a change under bin/ or lib/ that broke a suite ran
  # nothing: PR #34247 rewrote bin/masc_tui_msx.ml, dropped the line that writes
  # the image escape to the buffer, and left the MSX spectator drawing a title
  # and an empty screen. test_tui_msx_graphics had been asking for f=24 in that
  # output since #34221, and went red on main until #34259.
  #
  # The name is the mapping: module masc_tui_msx is covered by test_tui_msx_*,
  # with the masc_ prefix dropped. A module whose name prefixes more than
  # max_suites_per_module suites is a namespace rather than a unit --
  # bin/masc_tui.ml prefixes 136 of them -- and attributing those to one edit
  # says nothing, so it maps to none.
  #
  # Measured over origin/main's last 60 commits: 18 pick up at least one suite,
  # the largest picks up 6, and none reaches the max_suites cap above. Of the
  # 673 modules that match at all, the per-module cap drops 26.
  max_suites_per_module=4
  module_suites=""
  changed_sources=$( { printf '%s\n' "${changed}" \
    | grep -E '^(bin|lib)/.*\.ml$' || [ $? -eq 1 ]; } | sort -u)
  while IFS= read -r changed_source; do
    [ -n "${changed_source}" ] || continue
    stem=$(basename "${changed_source}" .ml)
    stem=${stem#masc_}
    # Both spellings: the suite named for the module, and the family under it.
    matches=$( { ls "test/test_${stem}.ml" "test/test_${stem}"_*.ml 2>/dev/null \
      || true; } | sort -u)
    [ -n "${matches}" ] || continue
    matched=$(printf '%s\n' "${matches}" | wc -l | tr -d ' ')
    if [ "${matched}" -gt "${max_suites_per_module}" ]; then
      echo "-- ${changed_source}: names ${matched} suites, too broad to attribute"
      continue
    fi
    module_suites=$(printf '%s\n%s\n' "${module_suites}" "${matches}")
  done <<SOURCES
  ${changed_sources}
SOURCES

  module_suites=$( { printf '%s\n' "${module_suites}" \
    | grep -v '^[[:space:]]*$' || [ $? -eq 1 ]; } | sort -u)

  if [ -z "${sources}" ] && [ -z "${assets}" ] && [ -z "${module_suites}" ]; then
    echo "no test source, config asset or named suite in this pull request"
      return 1
  fi

  count=$(printf '%s\n' "${sources}" | wc -l | tr -d ' ')
  echo "test sources this pull request edits: ${count}"
  printf '%s\n' "${sources}" | sed 's/^/  /'

  if [ "${count}" -gt "${max_suites}" ]; then
    echo "NOT RUN: more than ${max_suites} suites, which reads as a wrong list"
      return 1
  fi

  # After the cap, not before. The cap is a heuristic against a wrong
  # changed-file list; this guard is one named suite added for one stated
  # reason, so counting it toward that heuristic would let a pull request that
  # edits max_suites tests and one config asset run nothing at all -- worse
  # than before this mapping existed.
  if [ -n "${assets}" ]; then
    echo "this pull request changes managed config assets; adding ${asset_guard}"
    sources=$(printf '%s\n%s\n' "${sources}" "${asset_guard}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${module_suites}" ]; then
    echo "suites named after the sources this pull request edits:"
    printf '%s\n' "${module_suites}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${module_suites}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

}

# Fixtures for --self-test. Each is a changed-file list and the suites it must
# select; a mapping that stops selecting them, or starts selecting more, fails
# here rather than by going quiet on a later pull request.
self_test() {
  local failures=0
  check() {
    local label="$1" want="$2"
    shift 2
    changed=$(printf '%s\n' "$@")
    local got=""
    if select_sources > /dev/null 2>&1; then
      got=$(printf '%s\n' "${sources}" | grep -v '^[[:space:]]*$' | sort -u \
        | tr '\n' ' ' | sed 's/ $//')
    fi
    if [ "${got}" = "${want}" ]; then
      echo "ok   ${label}"
    else
      echo "FAIL ${label}"
      echo "     want: ${want:-<nothing>}"
      echo "     got:  ${got:-<nothing>}"
      failures=$((failures + 1))
    fi
  }

  # The regression this mapping exists for: #34247 edited only this module and
  # ran no suite, so the escape it dropped went to main.
  check "a source edit selects the suites named after it" \
    "test/test_tui_msx_graphics.ml test/test_tui_msx_load.ml" \
    "bin/masc_tui_msx.ml"
  # A module whose name is a namespace attributes nothing.
  check "an umbrella module selects nothing" "" \
    "bin/masc_tui.ml"
  check "a doc-only change selects nothing" "" \
    "docs/x.md"
  check "a config asset still reaches its guard" \
    "test/test_managed_assets_sync_from_binary.ml" "config/tools/foo.toml"
  check "an edited test is still selected on its own" \
    "test/test_tui_graphics.ml" "test/test_tui_graphics.ml"
  # Both halves together, deduplicated.
  check "a source and its own suite are one entry" \
    "test/test_tui_msx_graphics.ml test/test_tui_msx_load.ml" \
    "bin/masc_tui_msx.ml" "test/test_tui_msx_load.ml"

  if [ "${failures}" -eq 0 ]; then
    echo "run-edited-tests self-test: all cases pass"
    return 0
  fi
  echo "run-edited-tests self-test: ${failures} case(s) failed"
  return 1
}

if [ "${self_test_only}" = true ]; then
  cd "${repo_root}"
  self_test
  exit $?
fi

# The changed-file list comes from the pull request API, not from git. This
# job checks out at depth 1 plus tags, so a three-dot diff has no merge base
# and would answer with the whole tree.
changed=$(gh api "repos/${repo}/pulls/${pr_number}/files" \
  --paginate --jq '.[] | select(.status != "removed") | .filename')

select_sources || exit 0

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
  # What dune would supply and this does not: the files the stanza declares
  # as deps, and the environment its (setenv ...) action sets. The reader is
  # the one test.yml's targeted path already uses, so a suite run here and a
  # suite run there are given the same things. It errors rather than
  # guessing, and an error is this step's skip -- a suite run under the
  # wrong environment reports verdicts that look real.
  if ! stanza_deps=$(python3 "${stanza_reader}" --dir "${dir}" --deps "${name}" 2>&1); then
    echo "-- ${dir}/${name}: ${stanza_deps}"
    skipped=$((skipped + 1))
    continue
  fi
  if ! stanza_env=$(python3 "${stanza_reader}" --dir "${dir}" "${name}" 2>&1); then
    echo "-- ${dir}/${name}: ${stanza_env}"
    skipped=$((skipped + 1))
    continue
  fi
  deps=()
  while IFS= read -r target; do
    [ -n "${target}" ] && deps+=("${target}")
  done <<< "${stanza_deps}"
  stanza_setenv=()
  while IFS= read -r assignment; do
    [ -n "${assignment}" ] && stanza_setenv+=("${assignment}")
  done <<< "${stanza_env}"
  echo "== ${dir}/${name}"
  if ! dune build "${dir}/${name}.exe" ${deps+"${deps[@]}"} < /dev/null; then
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
         && env DUNE_SOURCEROOT="${repo_root}" \
            ${stanza_setenv+"${stanza_setenv[@]}"} \
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
