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
    | grep -E '(^|/)test/test_[a-z0-9_]+\.(ml|py)$' || [ $? -eq 1 ]; } | sort -u)

  # A .py suite is run by a dune rule rather than a linked executable, so it
  # is a suite only when a rule declares an alias for it; the other 25 under
  # test/ are helper modules a scenario imports, or scripts a workflow calls
  # by path. Measured 2026-09-13: 48 of the 73 test/test_*.py files carry one.
  #
  # Dropped here rather than in the run loop so --self-test covers the
  # decision. The loop runs what it is handed.
  runnable=""
  while IFS= read -r candidate; do
    candidate=$(printf '%s' "${candidate}" \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "${candidate}" ] || continue
    case "${candidate}" in
      *.py)
        stem=$(basename "${candidate}" .py)
        candidate_dir=$(dirname "${candidate}")
        # The alias can be declared in the dune file or in a stanza it
        # includes; 7 of the 48 are in an .inc. An unmatched glob leaves the
        # literal, which grep reports as a missing file on the discarded
        # stderr and does not match.
        if grep -qF "(alias runtest-${stem})" "${candidate_dir}/dune" \
          "${candidate_dir}"/stanzas/*.inc 2>/dev/null
        then
          runnable=$(printf '%s\n%s\n' "${runnable}" "${candidate}")
        else
          echo "-- ${candidate}: no dune rule declares runtest-${stem}"
        fi
        ;;
      *) runnable=$(printf '%s\n%s\n' "${runnable}" "${candidate}") ;;
    esac
  done <<CANDIDATES
${sources}
CANDIDATES
  sources=$( { printf '%s\n' "${runnable}" \
    | grep -v '^[[:space:]]*$' || [ $? -eq 1 ]; } | sort -u)

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

  # The same shape, one axis over: a deferred tool is offered to the model as
  # its description's first line, and test_keeper_tool_definition_source is
  # what says that line fits the budget it is offered in. A pull request that
  # adds config/tools/foo.toml edits no test/*.ml, so it never ran either.
  #
  # Measured 2026-09-08: #34409 brought twelve descriptions under the budget,
  # and within a day five MSX tools were added over it -- change_disk at 278
  # bytes, press at 745. The guard was green on main the whole time because
  # nothing ran it.
  # The ceiling on what every turn carries is the same shape again: #34409
  # grew the model-visible schemas by 664 bytes and the ratchet failed that
  # night, because the pull request edited config/tools and nothing else.
  # The file says growth "has to be argued for in the PR that causes it",
  # which needs the PR to be told.
  tools_changed=$( { printf '%s\n' "${changed}" \
    | grep -E '^config/tools/' || [ $? -eq 1 ]; } | head -1)
  tool_definition_guards="test/test_keeper_tool_definition_source.ml
test/test_keeper_tool_schema_bytes.ml
test/test_tools_coverage.ml"

  # The per-description bound, one axis in from the whole-surface ceiling.
  # test_tools_coverage reads Masc.Config.raw_all_tool_schemas -- the embedded
  # config/tools set -- and bounds each description at max_description_chars.
  # Nightly 34384710653 failed it on masc_browser_interact at 1,634 chars
  # against a 1,080 limit, and the pull request that grew it edited no
  # test/*.ml.

  # config/prompts is the same shape a third time. Every keeper turn is built
  # from the assembled system prompt, and test_keeper_system_prompt_bytes pins
  # it byte for byte for fixed inputs; it is the one suite that resolves the
  # repository's own config/prompts rather than a temp dir it wrote. The 44
  # other suites that name that directory pin the registry so the build does
  # not raise inside the dune sandbox, and assert nothing about what ships
  # there, so mapping them here would spend the whole budget on suites the
  # change cannot break. The same nightly measured the golden at 4,998 bytes
  # against an assembled 8,083.
  prompts_changed=$( { printf '%s\n' "${changed}" \
    | grep -E '^config/prompts/' || [ $? -eq 1 ]; } | head -1)
  prompt_guard="test/test_keeper_system_prompt_bytes.ml"


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
  #
  # packages/*/lib is in the scope for the same reason bin and lib are. It was
  # not, and neither test root was searched but the top one, so no edit under
  # agent_core selected a suite by name at all. Measured 2026-09-10: of 223
  # package sources, 94 name a suite, 79 of those within the per-module cap,
  # median 1. The 15 over the cap are the namespace modules the cap is for --
  # base/tool.ml names 61 suites, runtime.ml 31.
  max_suites_per_module=4
  module_suites=""
  changed_sources=$( { printf '%s\n' "${changed}" \
    | grep -E '^(bin|lib|packages/[^/]+/lib)/.*\.ml$' || [ $? -eq 1 ]; } | sort -u)
  while IFS= read -r changed_source; do
    [ -n "${changed_source}" ] || continue
    stem=$(basename "${changed_source}" .ml)
    stem=${stem#masc_}
    # Both spellings, in both test roots: the suite named for the module, and
    # the family under it.
    matches=$( { ls \
      "test/test_${stem}.ml" "test/test_${stem}"_*.ml \
      "packages/agent_core/test/test_${stem}.ml" \
      "packages/agent_core/test/test_${stem}"_*.ml 2>/dev/null \
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

  # A structural guard is named after what it asserts, not after the module it
  # reads, so the name mapping above cannot find it -- and the modules those
  # guards watch are the umbrella ones it deliberately skips. But such a guard
  # names its own input: it has the path in a string literal, because it opens
  # the file. Take the dependency from the literal rather than from the name.
  #
  # The regression this exists for: #35011 changed bin/masc_tui_render.ml,
  # which test_tui_http_ast watches through 52 Ast_grep ~module_path
  # declarations, and the name mapping looks for test_tui_render_* instead. The
  # pull request merged green and main was red on that suite until #35019.
  #
  # Matching the bare literal rather than ~module_path: reaching only through
  # that one helper made the rule about which API a guard uses. A guard that
  # opens the file itself watches its input just as much: 52 suites read a real
  # repository source without ever calling Ast_grep -- among them
  # test_blocker_class_mirror, which extracts the blocker class list straight
  # out of lib/keeper/keeper_meta_contract.ml.
  #
  # Every changed file, not the .ml subset the name mapping needs. A guard over
  # a shell script or a config file names it exactly the same way. The asset
  # and tool triggers above stay: they fire for any file under a directory,
  # which a named literal cannot say.
  # Measured 2026-09-10: 44 non-.ml files are named by a suite and exist --
  # 28 .sh, 3 .json, 2 .py, 2 .toml, 1 .ts, 1 .c -- the widest being
  # config/runtime.toml at 9 suites, inside the max_suites bound.
  #
  # Measured 2026-09-10: 132 source files are named this way across 78 suites;
  # 110 of them by exactly one suite, and bin/masc_tui_render.ml by the most, 8.
  # The per-module cap above does not apply -- it guards against a name that is
  # a namespace, and these are exact paths. max_suites still bounds the run.
  declared_suites=""
  while IFS= read -r changed_source; do
    # Trimmed, unlike the loop above: the heredoc indents its first line, and
    # that loop passes the value to basename, which does not care. This one
    # matches the path inside a string literal, where two leading spaces match
    # nothing and the miss is silent.
    changed_source=$(printf '%s' "${changed_source}" \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "${changed_source}" ] || continue
    # -F: the path carries a dot before the extension, and as a regex that
    # dot matches any character, so lib/foo.ml would also select a suite that
    # names lib/fooXml.
    watchers=$( { grep -rlF "\"${changed_source}\"" \
      test packages/agent_core/test --include='test_*.ml' 2>/dev/null \
      || true; } | sort -u)
    [ -n "${watchers}" ] || continue
    declared_suites=$(printf '%s\n%s\n' "${declared_suites}" "${watchers}")
  done <<DECLARED
  ${changed}
DECLARED

  declared_suites=$( { printf '%s\n' "${declared_suites}" \
    | grep -v '^[[:space:]]*$' || [ $? -eq 1 ]; } | sort -u)

  if [ -z "${sources}" ] && [ -z "${assets}" ] && [ -z "${module_suites}" ] \
    && [ -z "${declared_suites}" ]; then
    echo "no test source, config asset or named suite in this pull request"
      return 1
  fi

  count=$(printf '%s\n' "${sources}" | wc -l | tr -d ' ')
  echo "test sources this pull request edits: ${count}"
  printf '%s\n' "${sources}" | sed 's/^/  /'

  # Past the cap the name-derived lists are dropped and the run continues, so
  # the path-derived guards below still go. This used to return here, which
  # meant a pull request over the cap ran nothing at all -- including the
  # guards over config assets, which cannot be a wrong reading of the
  # changed-file list. #35025 turned this step from a report into a gate, so
  # running nothing is now a pull request passing the gate without a suite.
  # Measured 2026-09-09: #34889 renamed across more than twelve suites and the
  # log said NOT RUN.
  #
  # module_suites and declared_suites go with it. Both are derived from the
  # same changed-file list the cap distrusts, and both scale with its length;
  # a prefix match on config/tools does neither.
  if [ "${count}" -gt "${max_suites}" ]; then
    echo "DROPPED: more than ${max_suites} edited suites, which reads as a wrong list"
    echo "  name-derived lists go with it; the path-derived guards below do not"
    sources=""
    module_suites=""
    declared_suites=""
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

  if [ -n "${tools_changed}" ]; then
    echo "this pull request changes tool definitions; adding:"
    printf '%s\n' "${tool_definition_guards}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${tool_definition_guards}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${prompts_changed}" ]; then
    echo "this pull request changes prompt assets; adding ${prompt_guard}"
    sources=$(printf '%s\n%s\n' "${sources}" "${prompt_guard}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${module_suites}" ]; then
    echo "suites named after the sources this pull request edits:"
    printf '%s\n' "${module_suites}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${module_suites}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${declared_suites}" ]; then
    echo "guards that name the sources this pull request edits:"
    printf '%s\n' "${declared_suites}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${declared_suites}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  # The cap can leave nothing behind: a wide pull request that touches no
  # config asset drops its whole list here. The caller reads a return of 1 as
  # "this pull request has no suite to run", which is what that is.
  if [ -z "$(printf '%s\n' "${sources}" | grep -v '^[[:space:]]*$')" ]; then
    echo "no suite left to run"
    return 1
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
    "test/test_tui_msx_graphics.ml test/test_tui_msx_load.ml test/test_tui_msx_tick.ml" \
    "bin/masc_tui_msx.ml"
  # A module whose name is a namespace attributes nothing by name -- it
  # prefixes 136 suites, and picking those off one edit says nothing. What it
  # still selects is the four guards that name the file themselves. The name
  # mapping and the declared mapping answer different questions, and only the
  # first one has to stay quiet here.
  # test_tui_decode is here for a path inside a JSON fixture rather than a
  # read: it is one of the two such entries in 170 (source, suite) pairs, and
  # narrowing the match to exclude it would cost the guards that assign the
  # path to a plain let-binding.
  # test_tui_row_wiring joined when it grew ~module_path declarations over
  # this file: it pins that a surface's row count, its cursor and the landing
  # come from one record, and those are facts about masc_tui.ml.
  check "an umbrella module selects only the guards that name it" \
    "test/test_tui_agenda.ml test/test_tui_ask_selection_wiring.ml test/test_tui_chat_queue_wiring.ml test/test_tui_composer_projection.ml test/test_tui_decode.ml test/test_tui_http_ast.ml test/test_tui_row_wiring.ml" \
    "bin/masc_tui.ml"
  # The regression the declared mapping exists for: #35011 changed this file,
  # test_tui_http_ast watches it through 52 ~module_path declarations, and the
  # name mapping looks for test_tui_render_* instead. Both mappings answer
  # here, and the guard is in the answer.
  # test_tui_chat_gate_row left when the chat surface became its own file: it
  # watches the pane that draws the Gate row, and that pane is now in
  # bin/masc_tui_render_chat.ml, which it names instead. It is a move, not a
  # loss -- an edit to the chat surface still reaches it.
  check "a watched source reaches the guard that declares it" \
    "test/test_tui_agenda.ml test/test_tui_ask_selection_wiring.ml test/test_tui_chat_queue_wiring.ml test/test_tui_composer_projection.ml test/test_tui_config_highlight_wiring.ml test/test_tui_http_ast.ml test/test_tui_render_memory.ml test/test_tui_render_metrics.ml test/test_tui_render_schedule.ml test/test_tui_row_wiring.ml" \
    "bin/masc_tui_render.ml"
  # A guard that reads its input with open_in instead of Ast_grep is watching
  # it just the same. test_blocker_class_mirror pulls the blocker class list
  # out of this file and compares it to the dashboard mirror; the name mapping
  # looks for test_keeper_meta_contract_*, and there is no suite by that name,
  # so before this the only edit that ran the mirror was an edit to itself.
  check "a guard that opens its input is selected too" \
    "test/test_blocker_class_mirror.ml" \
    "lib/keeper/keeper_meta_contract.ml"
  # A package source names its suites the same way, in whichever test root
  # holds them. event_bus has one in each, which is why it is the fixture:
  # before this, an edit under packages/ selected nothing by name.
  check "a package source selects its suites in both test roots" \
    "packages/agent_core/test/test_event_bus.ml test/test_event_bus_subscription_contract.ml" \
    "packages/agent_core/lib/event_bus.ml"
  # The path matters: "docs/x.md" used to be the fixture here and stopped
  # meaning "no suite names this" -- test_tui_memory_facts_explorer carries it
  # as a source-fact path in its own fixture data. That is the coincidence any
  # literal match pays for, and it is one extra suite, not a wrong verdict.
  check "a doc no suite names selects nothing" "" \
    "docs/no-suite-names-this.md"
  # A guard can watch a document. Four do, among them the RFC-0086 namespace
  # invariant and this one, and before the declared mapping took every changed
  # path they were selected by nothing.
  check "a document a suite reads selects that suite" \
    "test/test_tui_render_memory.ml" \
    "docs/constitution.xml"
  # A tool definition reaches both: the one that says the asset embeds and
  # syncs, and the one that says its first line fits the line it is offered in.
  # Past the cap the name-derived list is dropped, and the path-derived guards
  # are not: config/tools cannot be a wrong reading of the changed-file list.
  # Before this, the cap returned before the guard blocks and the whole run was
  # nothing -- which #35025 turned from a quiet report into a gate a wide pull
  # request passes without running a suite.
  # The other side of the same drop: nothing else changed, so nothing is left
  # and the caller is told there is no suite -- the behaviour the cap had, kept
  # for the case the cap was written for.
  check "past the cap with no asset there is nothing left" \
    "" \
    test/test_wide_01.ml test/test_wide_02.ml test/test_wide_03.ml \
    test/test_wide_04.ml test/test_wide_05.ml test/test_wide_06.ml \
    test/test_wide_07.ml test/test_wide_08.ml test/test_wide_09.ml \
    test/test_wide_10.ml test/test_wide_11.ml test/test_wide_12.ml \
    test/test_wide_13.ml

  check "past the cap a tool definition still reaches its guards" \
    "test/test_keeper_tool_definition_source.ml test/test_keeper_tool_schema_bytes.ml test/test_managed_assets_sync_from_binary.ml test/test_tools_coverage.ml" \
    test/test_wide_01.ml test/test_wide_02.ml test/test_wide_03.ml \
    test/test_wide_04.ml test/test_wide_05.ml test/test_wide_06.ml \
    test/test_wide_07.ml test/test_wide_08.ml test/test_wide_09.ml \
    test/test_wide_10.ml test/test_wide_11.ml test/test_wide_12.ml \
    test/test_wide_13.ml config/tools/foo.toml

  check "a tool definition reaches every guard over it" \
    "test/test_keeper_tool_definition_source.ml test/test_keeper_tool_schema_bytes.ml test/test_managed_assets_sync_from_binary.ml test/test_tools_coverage.ml" \
    "config/tools/foo.toml"
  # Only tool definitions reach the second one; a prompt asset has no first
  # line to fit.
  check "a prompt asset reaches the asset guard and the prompt golden" \
    "test/test_keeper_system_prompt_bytes.ml test/test_managed_assets_sync_from_binary.ml" \
    "config/prompts/foo.md"
  check "an edited test is still selected on its own" \
    "test/test_tui_graphics.ml" "test/test_tui_graphics.ml"
  # Both halves together, deduplicated.
  check "a source and its own suite are one entry" \
    "test/test_tui_msx_graphics.ml test/test_tui_msx_load.ml test/test_tui_msx_tick.ml" \
    "bin/masc_tui_msx.ml" "test/test_tui_msx_load.ml"
  # The regression these two exist for: every terminal scenario under test/
  # is a .py run by a dune rule, and no pull request ran one. #35534 added
  # test_tui_wheel_notch.py, and the check log for it names the seven .ml
  # suites bin/masc_tui.ml is mapped to and not the scenario the pull request
  # wrote. The same gap was found for the five node rules (#34837) and closed
  # by building them unconditionally; a scenario that boots a terminal costs
  # 9s against their 0.7s, so it is attributed instead.
  check "an edited terminal scenario is selected" \
    "test/test_tui_keyboard_input.py" "test/test_tui_keyboard_input.py"
  # No dune rule declares an alias for this one, so nothing can run it and
  # selecting it would fail the step on a file that is not a suite.
  check "a .py with no rule of its own selects nothing" "" \
    "test/test_browser_activation.py"

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

# The suites main is known not to pass. The nightly ratchet holds this list in
# both directions -- a suite that fails unlisted is a new break, a listed one
# that passes has to come off -- so it is the record of what a pull request is
# not answerable for. Running one here and failing on it would stop a pull
# request for a break it did not cause, which is what kept this step advisory.
known_failures_file="test/ci-known-failures.txt"
known_failures=""
if [ -f "${known_failures_file}" ]; then
  known_failures=$( { grep -vE '^[[:space:]]*(#|$)' "${known_failures_file}" \
    || [ $? -eq 1 ]; } | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')
fi

is_known_failure() {
  printf '%s\n' "${known_failures}" | grep -Fxq "$1"
}

ran=0
skipped=0
failed=""
while IFS= read -r source; do
  [ -n "${source}" ] || continue
  dir=$(dirname "${source}")
  case "${source}" in
    *.py) name=$(basename "${source}" .py) ;;
    *) name=$(basename "${source}" .ml) ;;
  esac
  if is_known_failure "${dir}/${name}"; then
    echo "-- ${dir}/${name}: listed in ${known_failures_file}"
    skipped=$((skipped + 1))
    continue
  fi
  # A .py suite has no executable to build and run, so dune runs it: the rule
  # supplies the deps and the environment its action declares, which is what
  # the stanza reader below reconstructs by hand for a linked suite. Asked
  # for by path (@test/runtest-x, not @runtest-x) so a name that stopped
  # existing fails here instead of matching a rule in some other directory.
  #
  # Measured 2026-09-13: the alias exits 0 on a pass and 1 on a planted
  # failure, both forms, so this is a verdict and not a build line that
  # always reports success.
  case "${source}" in
    *.py)
      echo "== ${dir}/${name} (dune rule)"
      if ! timeout "${per_suite_timeout}" \
        dune build "@${dir}/runtest-${name}" < /dev/null
      then
        failed="${failed}${dir}/${name} (run)\n"
      else
        ran=$((ran + 1))
      fi
      continue
      ;;
  esac
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
