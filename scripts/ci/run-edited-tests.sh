#!/usr/bin/env bash
# Run the test suites this pull request's changes select, every one of them,
# within the step's budget; a suite the budget does not reach fails the step
# by name. RFC-0428.
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

# --self-test drives select_sources() and run_selected() over fixtures and
# never reaches the API, so it takes neither a pull-request number, a
# repository nor a budget.
self_test_only=false
[ "${1:-}" = "--self-test" ] && self_test_only=true

usage="usage: run-edited-tests.sh <pr-number> --budget-seconds <seconds> | --self-test"
if [ "${self_test_only}" = false ]; then
  pr_number="${1:?${usage}}"
  # The budget is the step's, and pr-check.yml sets the step's timeout-minutes
  # above it so this script, not the runner, ends a step that runs out.
  if [ "${2:-}" != "--budget-seconds" ] || ! [[ "${3:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${usage}" >&2
    exit 2
  fi
  budget_seconds="$3"
  repo="${MASC_TARGET_REPO:-${GITHUB_REPOSITORY}}"
fi
scope_tool="${repo_root}/scripts/ci/dune_suite_scope.py"
stanza_reader="${repo_root}/scripts/ci/stanza_env.py"
reference_tool="${repo_root}/scripts/ci/referencing_suites.py"

python_suite_is_runnable() {
  local stem candidate_dir
  stem=$(basename "$1" .py)
  candidate_dir=$(dirname "$1")
  grep -qF "(alias runtest-${stem})" "${candidate_dir}/dune" \
    "${candidate_dir}"/stanzas/*.inc 2>/dev/null
}

# Per suite, so one hang costs this step and not the job. The job's own
# timeout-minutes cancels everything and reports the job failed whatever a
# step's continue-on-error says.
per_suite_timeout=300

# WORKAROUND: production-blocking. One suite is a single walk of 74 PTY
# scenarios and legitimately takes longer than the bound above. It measures
# 261s locally and CI killed it at exactly 300.0s on two separate runs
# (14:19:05->14:24:05 and 14:38:55->14:43:55, #36343), so every pull request
# that edits that file is killed whatever it changed. #36349 is one: it
# repairs four broken layers of that walk, passes locally with no failures,
# and is why test/test_tui_keyboard_input is red on main.
#
# The bound stays 300s for every other suite. Raising it everywhere would
# double what a genuinely hung suite costs, which is what that bound is for.
#
# Removal target: #36343's split. Once enough of that walk's 69 inline
# scenarios live in focused suites of their own, the walk fits 300s again and
# this case goes with it. Nothing else belongs in this list -- a second entry
# means the split stopped being the plan.
suite_timeout() {
  case "$1" in
    */test_tui_keyboard_input.py) echo 600 ;;
    *) echo "${per_suite_timeout}" ;;
  esac
}

# Which suites this pull request runs, from its changed-file list in
# ${changed}. Sets ${sources} and returns 1 when there is nothing to run, so
# --self-test can exercise the same code the pull-request path does rather
# than a copy of it.
select_sources() {
  # One directory down as well. A suite under test/<dir>/ is a suite the same
  # way a flat one is -- the run loop builds it from its own directory -- but
  # the pattern required test_ to follow test/ directly, so editing one
  # selected nothing and the pull request that edited it ran no test of its
  # own. Measured 2026-09-14: 57 suites live under test/<dir>/, all exactly
  # one level down, against 1459 at the top. #36291 edited two of them and
  # the gate reported "test sources this pull request edits: 1".
  #
  # Guard grep's own no-match exit rather than the pipeline's: under pipefail a
  # bare `|| true` at the end also swallows a sed or sort that failed, and an
  # empty list then reads the same as "this pull request edits no tests".
  sources=$( { printf '%s\n' "${changed}" \
    | grep -E '(^|/)test/([a-z0-9_]+/)?test_[a-z0-9_]+\.(ml|py)$' \
      || [ $? -eq 1 ]; } | sort -u)

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
        # The alias can be declared in the dune file or in a stanza it
        # includes; 7 of the 48 are in an .inc. An unmatched glob leaves the
        # literal, which grep reports as a missing file on the discarded
        # stderr and does not match.
        if python_suite_is_runnable "${candidate}"
        then
          runnable=$(printf '%s\n%s\n' "${runnable}" "${candidate}")
        else
          echo "-- ${candidate}: no dune rule declares runtest-$(basename "${candidate}" .py)"
        fi
        ;;
      *) runnable=$(printf '%s\n%s\n' "${runnable}" "${candidate}") ;;
    esac
  done <<CANDIDATES
${sources}
CANDIDATES
  sources=$( { printf '%s\n' "${runnable}" \
    | grep -v '^[[:space:]]*$' || [ $? -eq 1 ]; } | sort -u)
  # Keep the suites this pull request edits as their own execution class.
  # Source-derived guards can expand one test edit into hundreds of suites;
  # if all names are sorted together, the test carrying the changed assertion
  # may receive only the tail of the step budget. Selection stays complete,
  # but [run_selected] executes this class before attributed suites.
  direct_sources="${sources}"

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
  #
  # And a fourth guard over the same files: whether a tool is deferred is
  # declared in its own config/tools file, and test_tool_loading_declarations
  # pins what those declarations say. #36681 deferred twelve built-ins by
  # editing twelve of those files and nothing else; the suite went red on
  # keeper_tools_list and stayed red until #36773.
  tool_definition_guards="test/test_keeper_tool_definition_source.ml
test/test_keeper_tool_schema_bytes.ml
test/test_tool_loading_declarations.ml
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

  # config/themes is the same shape a fourth time, and the only one of the
  # three where the suite is not in doubt. 53 base16 schemes ship out of that
  # directory; test_tui_theme_contrast measures every one of them through
  # Catalog.all -- foreground against background, the receding token, the
  # whole palette -- and it is the only suite that names the directory at all.
  # An edit there selected nothing, so a scheme could ship with a pair the
  # harness would have refused.
  #
  # Why a trigger rather than the quoted-literal rule below: that rule matches
  # the changed path itself, and a theme file is never named by a suite -- the
  # suite names the directory it reads the whole of. Widening the rule to
  # quoted ancestor directories was measured and is worse: "lib" is quoted by
  # 25 suites over 3,409 files and "config/prompts" by 26, against the one
  # suite the prompt trigger above deliberately picks. A directory that a
  # whole harness stands over is named here, where it can be argued for.
  themes_changed=$( { printf '%s\n' "${changed}" \
    | grep -E '^config/themes/' || [ $? -eq 1 ]; } | head -1)
  theme_guard="test/test_tui_theme_contrast.ml"


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
  # the largest picks up 6. Of the 673 modules that match at all, the
  # per-module cap drops 26.
  #
  # packages/*/lib is in the scope for the same reason bin and lib are. It was
  # not, and neither test root was searched but the top one, so no edit under
  # agent_core selected a suite by name at all. Measured 2026-09-10: of 223
  # package sources, 94 name a suite, 79 of those within the per-module cap,
  # median 1. The 15 over the cap are the namespace modules the cap is for --
  # base/tool.ml names 61 suites, runtime.ml 31.
  #
  # An interface edit is an edit to the same module. The scope took .ml only,
  # so a change to foo.mli alone ran none of test_foo_*: an interface can
  # change a contract's doc, or a signature the suite exercises through a
  # different caller, with the implementation untouched. Measured 2026-09-14
  # over origin/main's last 60 commits: 7 edited an .mli without its .ml and
  # named a suite within the cap -- among them #36279, whose suite over the
  # function it re-documented did not run.
  max_suites_per_module=4
  module_suites=""
  changed_sources=$( { printf '%s\n' "${changed}" \
    | grep -E '^(bin|lib|packages/[^/]+/lib)/.*\.mli?$' || [ $? -eq 1 ]; } | sort -u)
  while IFS= read -r changed_source; do
    [ -n "${changed_source}" ] || continue
    stem=$(basename "${changed_source}")
    stem=${stem%.mli}
    stem=${stem%.ml}
    stem=${stem#masc_}
    # Both spellings, in both test roots: the suite named for the module, and
    # the family under it.
    #
    # And the same two spellings one directory down. A suite with its own
    # directory is the same claim about the same module -- test/voice_catalog
    # is what test_voice_catalog.ml would have been -- but the flat glob never
    # reached it, so no edit to the module it is named for selected it.
    # Measured 2026-09-14: 57 suites live under test/<dir>/, 33 of them named
    # for their directory. The per-module cap below applies to these too, so a
    # directory holding a family of suites is attributed or skipped as one.
    matches=$( { ls \
      "test/test_${stem}.ml" "test/test_${stem}"_*.ml \
      "test/${stem}/test_${stem}.ml" "test/${stem}/test_${stem}"_*.ml \
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

  # A third way a suite says which module it stands over: its dune stanza
  # links it. bin/ TUI libraries are (wrapped false) single-module libraries,
  # so the library name is the module name, and a suite that lists it in
  # (libraries ...) is built against that module and nothing between them.
  #
  # The two rules above miss exactly the suites named after what they assert
  # rather than after a module, when they also do not open a file. The
  # regression: test_tui_theme_contrast measures all 53 shipped base16 schemes
  # -- foreground against background, the receding token, the whole palette --
  # and links masc_tui_color, masc_tui_theme_catalog and masc_tui_theme_choice.
  # None of those three selected it, so the contrast formula itself could
  # change with that harness never run.
  #
  # Measured 2026-09-15 over the 138 bin/masc_tui*.ml modules: eight that
  # selected nothing now select one to three suites, and the whole set gains
  # 63 selections -- 0.46 a module. The cap above applies unchanged and is
  # what keeps the wide ones out: masc_tui_types is linked by 58 suites,
  # masc_tui_message_layout by 34, masc_tui_theme by 15.
  library_suites=""
  while IFS= read -r changed_source; do
    changed_source=$(printf '%s' "${changed_source}" \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "${changed_source}" ] || continue
    stem=$(basename "${changed_source}")
    stem=${stem%.mli}
    stem=${stem%.ml}
    # One pass over the stanzas, tracking the (name ...) each (libraries ...)
    # belongs to. A (test ...) with no libraries resets on the next one rather
    # than lending its name to the following stanza.
    matches=$(awk -v want="${stem}" '
      /\(test$|\(test[ \t]/ { in_test = 1; name = "" }
      in_test && match($0, /\(name[ \t]+[A-Za-z0-9_]+/) {
        if (name == "") { name = substr($0, RSTART + 6, RLENGTH - 6); gsub(/[ \t]/, "", name) }
      }
      in_test && /\(libraries/ { in_libs = 1; sub(/.*\(libraries/, "") }
      in_libs {
        line = $0
        gsub(/\)/, " ", line)
        n = split(line, tok, /[ \t]+/)
        for (i = 1; i <= n; i++) if (tok[i] == want && name != "") print "test/" name ".ml"
        if ($0 ~ /\)/) { in_libs = 0; in_test = 0 }
      }
    ' test/dune test/stanzas/*.inc 2>/dev/null | sort -u)
    [ -n "${matches}" ] || continue
    matched=$(printf '%s\n' "${matches}" | wc -l | tr -d ' ')
    if [ "${matched}" -gt "${max_suites_per_module}" ]; then
      echo "-- ${changed_source}: ${matched} suites link it, too broad to attribute"
      continue
    fi
    library_suites=$(printf '%s\n%s\n' "${library_suites}" "${matches}")
  done <<LIBSOURCES
  ${changed_sources}
LIBSOURCES

  library_suites=$( { printf '%s\n' "${library_suites}" \
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
  # config/runtime.toml at 9 suites.
  #
  # Measured 2026-09-10: 132 source files are named this way across 78 suites;
  # 110 of them by exactly one suite, and bin/masc_tui_render.ml by the most, 8.
  # The per-module cap above does not apply -- it guards against a name that is
  # a namespace, and these are exact paths. Python PTY suites declare their
  # source inputs in the same way (SOURCE_MODULES); a helper without a runnable
  # dune alias must not become a suite merely because it mentions a path.
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
      test packages/agent_core/test --include='test_*.ml' --include='test_*.py' 2>/dev/null \
      || true; } | sort -u)
    [ -n "${watchers}" ] || continue
    while IFS= read -r watcher; do
      case "${watcher}" in
        *.py) python_suite_is_runnable "${watcher}" || continue ;;
      esac
      declared_suites=$(printf '%s\n%s\n' "${declared_suites}" "${watcher}")
    done <<WATCHERS
${watchers}
WATCHERS
  done <<DECLARED
  ${changed}
DECLARED

  declared_suites=$( { printf '%s\n' "${declared_suites}" \
    | grep -v '^[[:space:]]*$' || [ $? -eq 1 ]; } | sort -u)

  # Every mapping above asks a suite for its name, its stanza or a quoted
  # path. None asks what its code calls, and three pull requests merged with a
  # suite red that only that question reaches: #29365 changed
  # Env_config_keeper, which test_runtime_toml_overrides calls; #36885 changed
  # Runtime_setup_spec, which test_runtime_setup_batch and
  # test_server_runtime_setup_actions call, and scripts/install-runtime-setup.py,
  # which test_install_runtime_setup.py runs. referencing_suites.py reads the
  # code with comments and strings removed for a changed module, and every
  # suite's text for a changed file whose name no other tracked file has.
  #
  # No per-module cap. The caps above drop what they cannot attribute; this
  # selects what calls the change, and whatever it selects runs -- a pull
  # request whose suites do not fit the step fails naming them rather than
  # passing without them. Measured 2026-09-17 over origin/main's last 80
  # pull requests with the other mappings: 18 of them had a suite the name
  # and link mappings chose that the module rule alone does not, so those
  # stay.
  #
  # A helper failure ends the step here. This function is called under ||,
  # which turns off errexit, and an empty answer would read as "nothing calls
  # this".
  if ! referenced=$(printf '%s\n' "${changed}" | python3 "${reference_tool}"); then
    echo "referencing_suites.py failed"
    exit 1
  fi
  referencing_suites=$(printf '%s\n' "${referenced}" | sed -n 's/^module //p')
  named_file_candidates=$(printf '%s\n' "${referenced}" | sed -n 's/^file //p')
  named_file_suites=""
  while IFS= read -r candidate; do
    [ -n "${candidate}" ] || continue
    case "${candidate}" in
      *.py) python_suite_is_runnable "${candidate}" || continue ;;
    esac
    named_file_suites=$(printf '%s\n%s\n' "${named_file_suites}" "${candidate}")
  done <<NAMEDFILES
${named_file_candidates}
NAMEDFILES
  named_file_suites=$( { printf '%s\n' "${named_file_suites}" \
    | grep -v '^[[:space:]]*$' || [ $? -eq 1 ]; } | sort -u)

  # [themes_changed] stands beside [assets] here: the tool and prompt triggers
  # ride that variable, which matches config/(prompts|tools|mcp), and a theme
  # is none of those. Left out, a theme-only pull request returned here before
  # reaching the trigger below and reported no suite at all.
  if [ -z "${sources}" ] && [ -z "${assets}" ] && [ -z "${themes_changed}" ] \
    && [ -z "${module_suites}" ] && [ -z "${library_suites}" ] \
    && [ -z "${declared_suites}" ] && [ -z "${referencing_suites}" ] \
    && [ -z "${named_file_suites}" ]; then
    echo "no test source, config asset or named suite in this pull request"
      return 1
  fi

  count=$(printf '%s\n' "${sources}" | wc -l | tr -d ' ')
  echo "test sources this pull request edits: ${count}"
  printf '%s\n' "${sources}" | sed 's/^/  /'

  # Preserve every attributed suite, including wide pull requests. The caller's
  # job timeout reports a real failure if execution cannot finish; list length
  # must not turn required assertions into a successful no-test result.
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

  if [ -n "${themes_changed}" ]; then
    echo "this pull request changes theme assets; adding ${theme_guard}"
    sources=$(printf '%s\n%s\n' "${sources}" "${theme_guard}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${module_suites}" ]; then
    echo "suites named after the sources this pull request edits:"
    printf '%s\n' "${module_suites}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${module_suites}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${library_suites}" ]; then
    echo "suites whose dune stanza links the sources this pull request edits:"
    printf '%s\n' "${library_suites}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${library_suites}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${declared_suites}" ]; then
    echo "guards that name the sources this pull request edits:"
    printf '%s\n' "${declared_suites}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${declared_suites}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${referencing_suites}" ]; then
    echo "suites whose code calls a module this pull request edits:"
    printf '%s\n' "${referencing_suites}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${referencing_suites}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  if [ -n "${named_file_suites}" ]; then
    echo "suites that name a file this pull request edits:"
    printf '%s\n' "${named_file_suites}" | sed 's/^/  /'
    sources=$(printf '%s\n%s\n' "${sources}" "${named_file_suites}" \
      | grep -v '^[[:space:]]*$' | sort -u)
  fi

  # Return no selection only when no input mapped to a runnable suite.
  if ! printf '%s\n' "${sources}" | grep -v '^[[:space:]]*$' > /dev/null; then
    echo "no suite left to run"
    return 1
  fi
}

# Seconds left of the step's budget. SECONDS counts from this shell's start,
# which is the step's start to within reading the file list.
budget_left() {
  echo $(( budget_seconds - SECONDS ))
}

# A suite's own bound, or what is left of the budget when that is less.
bounded_by_budget() {
  local own="$1" left
  left=$(budget_left)
  if [ "${left}" -lt "${own}" ]; then
    echo "${left}"
  else
    echo "${own}"
  fi
}

# Runs ${sources}; sets ${ran}, ${skipped} and ${failed}.
#
# Everything selected runs, and the budget is what bounds it (RFC-0428,
# "넓힌 선택"). A suite the budget does not reach is named in ${failed}: the
# selection grew about threefold, and a step that passed without the suites
# it had no time for would read as those suites passing.
#
# The linked suites are built by one dune invocation rather than one each.
# Measured in run 35216373548, one at a time: 71s for the first suite, which
# compiles the shared libraries, then 9s, 7s and 4s; at that rate the p90
# selection of 78 suites does not fit a 12-minute step. _build starts empty
# on every run -- only the opam switch is cached -- so an executable present
# after that build was linked from this checkout, and one absent failed to
# link.
run_selected() {
  local known_failures_file="test/ci-known-failures.txt"
  local known_failures=""
  if [ -f "${known_failures_file}" ]; then
    known_failures=$( { grep -vE '^[[:space:]]*(#|$)' "${known_failures_file}" \
      || [ $? -eq 1 ]; } | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')
  fi

  ran=0
  skipped=0
  failed=""
  local direct_group="" attributed_group="" source

  # A directly edited suite is the closest executable claim about the changed
  # assertion. Run that finite class first, then every suite attributed from
  # source, stanza, guard, or reference analysis. This changes only execution
  # order: no selected suite is dropped or treated as passing without running.
  while IFS= read -r source; do
    [ -n "${source}" ] || continue
    if printf '%s\n' "${direct_sources:-}" | grep -Fxq "${source}"
    then direct_group=$(printf '%s\n%s\n' "${direct_group}" "${source}")
    else attributed_group=$(printf '%s\n%s\n' "${attributed_group}" "${source}")
    fi
  done <<EOF
${sources}
EOF

  local group_sources
  for group_sources in "${direct_group}" "${attributed_group}"; do
    if ! printf '%s\n' "${group_sources}" | grep -q '[^[:space:]]'; then
      continue
    fi
    # Indexed arrays with a separate count: macOS's bash 3.2 treats an empty
    # "${a[@]}" as unbound under nounset.
    local linked_ids=() linked_deps=() linked_envs=() linked_count=0
    local python_sources=() python_count=0
    local dir name verdict stanza_deps stanza_env

  while IFS= read -r source; do
    [ -n "${source}" ] || continue
    dir=$(dirname "${source}")
    case "${source}" in
      *.py) name=$(basename "${source}" .py) ;;
      *) name=$(basename "${source}" .ml) ;;
    esac
    # The suites main is known not to pass. The nightly ratchet holds this
    # list in both directions -- a suite that fails unlisted is a new break, a
    # listed one that passes has to come off -- so it is the record of what a
    # pull request is not answerable for.
    if printf '%s\n' "${known_failures}" | grep -Fxq "${dir}/${name}"; then
      echo "-- ${dir}/${name}: listed in ${known_failures_file}"
      skipped=$((skipped + 1))
      continue
    fi
    case "${source}" in
      *.py)
        python_sources[python_count]="${source}"
        python_count=$((python_count + 1))
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
    # What dune would supply and a direct run does not: the files the stanza
    # declares as deps, and the environment its (setenv ...) action sets. The
    # reader is the one test.yml's targeted path uses. It errors rather than
    # guessing, and an error is a skip -- a suite run under the wrong
    # environment reports verdicts that look real.
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
    linked_ids[linked_count]="${dir}/${name}"
    linked_deps[linked_count]="${stanza_deps}"
    linked_envs[linked_count]="${stanza_env}"
    linked_count=$((linked_count + 1))
    done <<EOF
${group_sources}
EOF

    local i id target left limit status binary
    local targets=() target_count=0 build_status=0 build_ran_out=false
    local linked_built=()
    i=0
    while [ "${i}" -lt "${linked_count}" ]; do
    targets[target_count]="${linked_ids[i]}.exe"
    target_count=$((target_count + 1))
    while IFS= read -r target; do
      [ -n "${target}" ] || continue
      targets[target_count]="${target}"
      target_count=$((target_count + 1))
    done <<DEPS
${linked_deps[i]}
DEPS
    linked_built[i]=true
    i=$((i + 1))
    done
    if [ "${linked_count}" -gt 0 ]; then
    left=$(budget_left)
    if [ "${left}" -le 0 ]; then
      build_ran_out=true
    else
      echo "== building ${linked_count} suites in one dune invocation"
      timeout "${left}" dune build "${targets[@]}" < /dev/null || build_status=$?
      [ "${build_status}" -ne 124 ] || build_ran_out=true
    fi
    fi
  # A failed invocation says something failed, not which suite. An absent
  # executable is that suite's. A present one whose stanza also declares
  # deps may still have lost a dep, so those are asked again one at a time;
  # dune answers at once for what is already built.
    if [ "${build_status}" -ne 0 ] && [ "${build_ran_out}" = false ]; then
    i=0
    while [ "${i}" -lt "${linked_count}" ]; do
      id=${linked_ids[i]}
      if [ ! -x "${repo_root}/_build/default/${id}.exe" ]; then
        linked_built[i]=false
      elif [ -n "${linked_deps[i]}" ]; then
        left=$(budget_left)
        if [ "${left}" -le 0 ]; then
          build_ran_out=true
          break
        fi
        targets=("${id}.exe")
        while IFS= read -r target; do
          [ -n "${target}" ] && targets+=("${target}")
        done <<DEPS
${linked_deps[i]}
DEPS
        timeout "${left}" dune build "${targets[@]}" < /dev/null || linked_built[i]=false
      fi
      i=$((i + 1))
    done
    fi

    i=0
    while [ "${i}" -lt "${linked_count}" ]; do
    id=${linked_ids[i]}
    dir=${id%/*}
    name=${id##*/}
    i=$((i + 1))
    binary="${repo_root}/_build/default/${id}.exe"
    if [ ! -x "${binary}" ] && [ "${build_ran_out}" = true ]; then
      failed="${failed}${id} (not built: the step budget ran out)\n"
      continue
    fi
    if [ "${linked_built[i - 1]}" = false ]; then
      failed="${failed}${id} (build)\n"
      continue
    fi
    if [ ! -x "${binary}" ]; then
      # The build reported success and the binary is not where dune puts it,
      # which is a different thing from a suite that failed to link.
      failed="${failed}${id} (built, but no binary at ${binary})\n"
      continue
    fi
    if [ "$(budget_left)" -le 0 ]; then
      failed="${failed}${id} (not run: the step budget ran out)\n"
      continue
    fi
    limit=$(bounded_by_budget "${per_suite_timeout}")
    local stanza_setenv=()
    while IFS= read -r assignment; do
      [ -n "${assignment}" ] && stanza_setenv+=("${assignment}")
    done <<ENVS
${linked_envs[i - 1]}
ENVS
    echo "== ${id}"
    status=0
    # dune runs a suite from inside its own build directory, and suites read
    # relative paths from there. DUNE_SOURCEROOT is what the ones that want
    # the checkout read; without it they fall back to the cwd, which from
    # here would be the wrong tree.
    ( cd "${repo_root}/_build/default/${dir}" \
      && env DUNE_SOURCEROOT="${repo_root}" \
         ${stanza_setenv+"${stanza_setenv[@]}"} \
         timeout "${limit}" "./${name}.exe" < /dev/null ) || status=$?
    if [ "${status}" -eq 0 ]; then
      ran=$((ran + 1))
    elif [ "${status}" -eq 124 ] && [ "${limit}" -lt "${per_suite_timeout}" ]; then
      failed="${failed}${id} (stopped at the step budget after ${limit}s)\n"
    else
      failed="${failed}${id} (run)\n"
    fi
    done

  # A .py suite has no executable to build and run, so dune runs it: the rule
  # supplies the deps and the environment its action declares. Asked for by
  # path (@test/runtest-x, not @runtest-x) so a name that stopped existing
  # fails here instead of matching a rule in some other directory.
  # Measured 2026-09-13: the alias exits 0 on a pass and 1 on a planted
  # failure, both forms, so this is a verdict and not a build line that
  # always reports success.
    i=0
    while [ "${i}" -lt "${python_count}" ]; do
    source=${python_sources[i]}
    i=$((i + 1))
    dir=$(dirname "${source}")
    name=$(basename "${source}" .py)
    if [ "$(budget_left)" -le 0 ]; then
      failed="${failed}${dir}/${name} (not run: the step budget ran out)\n"
      continue
    fi
    local own
    own=$(suite_timeout "${source}")
    limit=$(bounded_by_budget "${own}")
    echo "== ${dir}/${name} (dune rule)"
    status=0
    timeout "${limit}" dune build "@${dir}/runtest-${name}" < /dev/null || status=$?
    if [ "${status}" -eq 0 ]; then
      ran=$((ran + 1))
    elif [ "${status}" -eq 124 ] && [ "${limit}" -lt "${own}" ]; then
      failed="${failed}${dir}/${name} (stopped at the step budget after ${limit}s)\n"
    else
      failed="${failed}${dir}/${name} (run)\n"
    fi
    done
  done
}

# Fixtures for --self-test. Each is a changed-file list and the suites it must
# select; a mapping that stops selecting them, or starts selecting more, fails
# here rather than by going quiet on a later pull request.
self_test() {
  local failures=0
  # A fresh PR invocation has no [stem] left by earlier source-mapping cases.
  # Exercise the real no-alias path first under nounset; a prior self-test
  # accidentally supplied the out-of-scope helper local through a global.
  (
    unset stem
    changed="test/test_release_evidence_report.py"
    select_sources && exit 1
    [ -z "${sources}" ]
  ) || { echo "FAIL fresh Python helper selection"; return 1; }
  check() {
    local label="$1" want="$2"
    shift 2
    changed=$(printf '%s\n' "$@")
    local got=""
    if select_sources > /dev/null 2>&1; then
      # LC_ALL=C: the first case whose two suites differ only at "." against
      # "_" -- test_tui_browser.ml and test_tui_browser_history.py -- ordered
      # one way on a developer's machine and the other on the runner, because
      # a locale collation that ignores punctuation reverses them. The order
      # here decides whether a case passes, so it is pinned rather than
      # inherited.
      got=$(printf '%s\n' "${sources}" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u \
        | tr '\n' ' ' | sed 's/ $//')
    fi
    local matches=false
    if [ "${allow_additional:-false}" = true ]; then
      matches=true
      for required in ${want}; do
        case " ${got} " in
          *" ${required} "*) ;;
          *) matches=false ;;
        esac
      done
      # The shared dispatcher is not a reason to launch the entire keyboard
      # suite. Only explicitly attributed focused PTY scenarios belong here.
      case " ${got} " in
        *" test/test_tui_keyboard_input.py "*) matches=false ;;
      esac
    elif [ "${got}" = "${want}" ]; then
      matches=true
    fi
    if [ "${matches}" = true ]; then
      echo "ok   ${label}"
    else
      echo "FAIL ${label}"
      echo "     want: ${want:-<nothing>}"
      echo "     got:  ${got:-<nothing>}"
      failures=$((failures + 1))
    fi
  }
  check_required() {
    # Live umbrella modules gain legitimate watchers as other PRs add tests.
    # Assert the required coverage and exclusion, without freezing that set.
    local allow_additional=true
    check "$@"
  }

  # The regression this mapping exists for: #34247 edited only this module and
  # ran no suite, so the escape it dropped went to main.
  check "a source edit selects the suites named after it" \
    "test/test_tui_msx_graphics.ml test/test_tui_msx_load.ml test/test_tui_msx_tick.ml" \
    "bin/masc_tui_msx.ml"
  # A module whose name is a namespace attributes nothing by name -- it
  # prefixes 136 suites, and picking those off one edit says nothing. What it
  # still selects is the guards and PTY scenarios that name the file. The name
  # mapping and the declared mapping answer different questions, and only the
  # first one has to stay quiet here.
  # test_tui_decode is here for a path inside a JSON fixture rather than a
  # read: it is one of the two such entries in 170 (source, suite) pairs, and
  # narrowing the match to exclude it would cost the guards that assign the
  # path to a plain let-binding.
  # test_tui_row_wiring joined when it grew ~module_path declarations over
  # this file: it pins that a surface's row count, its cursor and the landing
  # come from one record, and those are facts about masc_tui.ml.
  # test_tui_voice_wizard_wiring joined with the voice setup wizard: the
  # wizard's rules live in Voice_wizard and its session in Masc_tui_types, and
  # neither can say that a key in this file reaches them. It declares this file
  # because the claim it holds -- that every session mover has a key -- is a
  # fact about this dispatcher.
  check_required "an umbrella module selects its guards and declared PTY scenario" \
    "test/test_tui_agenda.ml test/test_tui_ask_selection_wiring.ml test/test_tui_chat_queue_wiring.ml test/test_tui_composer_projection.ml test/test_tui_decode.ml test/test_tui_http_ast.ml test/test_tui_reading_ends.py test/test_tui_row_wiring.ml test/test_tui_voice_wizard_wiring.ml" \
    "bin/masc_tui.ml"
  # The regression the declared mapping exists for: #35011 changed this file,
  # test_tui_http_ast watches it through 52 ~module_path declarations, and the
  # name mapping looks for test_tui_render_* instead. Both mappings answer
  # here, and the guard is in the answer.
  # test_tui_chat_gate_row left when the chat surface became its own file: it
  # watches the pane that draws the Gate row, and that pane is now in
  # bin/masc_tui_render_chat.ml, which it names instead. It is a move, not a
  # loss -- an edit to the chat surface still reaches it.
  # Two joined with the voice setup wizard. test_tui_voice_wizard_wiring pins
  # that the pane hands over to the wizard and that the step counter is
  # computed rather than restated; test_tui_config_key_help_matches_the_panes
  # takes the pane count out of the strip this file draws, so an added pane
  # moves it.
  # test_tui_tab_strip joined when it began reading this file: the Runtime
  # header's two views must be drawn by tab_strip, and render_runtime is here.
  check_required "a watched source reaches the guard that declares it" \
    "test/test_tui_agenda.ml test/test_tui_ask_selection_wiring.ml test/test_tui_chat_queue_wiring.ml test/test_tui_composer_projection.ml test/test_tui_config_highlight_wiring.ml test/test_tui_http_ast.ml test/test_tui_reading_ends.py test/test_tui_render_memory.ml test/test_tui_render_metrics.ml test/test_tui_render_schedule.ml test/test_tui_render_tools.ml test/test_tui_row_wiring.ml test/test_tui_tab_strip.ml test/test_tui_voice_wizard_wiring.ml" \
    "bin/masc_tui_render.ml"
  # A guard that reads its input with open_in instead of Ast_grep is watching
  # it just the same. test_blocker_class_mirror pulls the blocker class list
  # out of this file and compares it to the dashboard mirror; the name mapping
  # looks for test_keeper_meta_contract_*, and there is no suite by that name,
  # so before this the only edit that ran the mirror was an edit to itself.
  # The regression this declaration exists for: #36290 narrowed the tab strip
  # in this module, and the scenario that reads a tab name off the row lived
  # only inside the whole-screen walk -- which names no source. Nothing ran.
  # It merged green and main was red until #36327.
  check_required "the shared chrome selects the strip scenario" \
    "test/test_tui_tab_strip_pty.py" \
    "bin/masc_tui_ansi.ml"
  # The five cases below were exact before the module rule: each module is
  # also called by suites that neither carry its name nor quote its path, and
  # those now run too. What each case pins is the suite it was written for.
  check_required "a guard that opens its input is selected too" \
    "test/test_blocker_class_mirror.ml" \
    "lib/keeper/keeper_meta_contract.ml"
  # A package source names its suites the same way, in whichever test root
  # holds them. event_bus has one in each, which is why it is the fixture:
  # before this, an edit under packages/ selected nothing by name.
  check_required "a package source selects its suites in both test roots" \
    "packages/agent_core/test/test_event_bus.ml test/test_event_bus_subscription_contract.ml" \
    "packages/agent_core/lib/event_bus.ml"
  # A suite with its own directory is named for its module the same way, and
  # the flat glob never looked there. The fixture is voice_wizard because that
  # is where it was measured: #36098 and #36124 both changed lib/voice_setup
  # and lib/voice_wizard, both merged green, and both had to have these suites
  # run by hand afterwards -- the first time, after main was already red.
  check_required "a module with its own test directory selects the suite in it" \
    "test/voice_wizard/test_voice_wizard.ml" \
    "lib/voice_wizard/voice_wizard.ml"
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
  # Thirteen edited suites used to be discarded, including every source-derived
  # guard. A wide change must retain its tests with or without an asset edit.
  local wide_sources="test/test_wide_01.ml test/test_wide_02.ml test/test_wide_03.ml test/test_wide_04.ml test/test_wide_05.ml test/test_wide_06.ml test/test_wide_07.ml test/test_wide_08.ml test/test_wide_09.ml test/test_wide_10.ml test/test_wide_11.ml test/test_wide_12.ml test/test_wide_13.ml"
  check "thirteen edited suites all remain selected" \
    "${wide_sources}" \
    test/test_wide_01.ml test/test_wide_02.ml test/test_wide_03.ml \
    test/test_wide_04.ml test/test_wide_05.ml test/test_wide_06.ml \
    test/test_wide_07.ml test/test_wide_08.ml test/test_wide_09.ml \
    test/test_wide_10.ml test/test_wide_11.ml test/test_wide_12.ml \
    test/test_wide_13.ml

  check "thirteen edited suites retain both themselves and asset guards" \
    "test/test_keeper_tool_definition_source.ml test/test_keeper_tool_schema_bytes.ml test/test_managed_assets_sync_from_binary.ml test/test_tool_loading_declarations.ml test/test_tools_coverage.ml ${wide_sources}" \
    test/test_wide_01.ml test/test_wide_02.ml test/test_wide_03.ml \
    test/test_wide_04.ml test/test_wide_05.ml test/test_wide_06.ml \
    test/test_wide_07.ml test/test_wide_08.ml test/test_wide_09.ml \
    test/test_wide_10.ml test/test_wide_11.ml test/test_wide_12.ml \
    test/test_wide_13.ml config/tools/foo.toml

  check "a tool definition reaches every guard over it" \
    "test/test_keeper_tool_definition_source.ml test/test_keeper_tool_schema_bytes.ml test/test_managed_assets_sync_from_binary.ml test/test_tool_loading_declarations.ml test/test_tools_coverage.ml" \
    "config/tools/foo.toml"
  # The three regressions the module and file-name rules exist for, with the
  # source files each pull request changed.
  check_required "#29365: a module edit reaches the suite that calls it" \
    "test/test_runtime_toml_overrides.ml" \
    lib/config/env_config_keeper.ml lib/config/env_config_keeper.mli \
    lib/config/keeper_runtime_setting_registry.ml \
    lib/keeper/keeper_heartbeat_stimulus_intake.ml \
    lib/schedule/schedule_domain.ml lib/schedule/schedule_domain.mli
  check_required "#36885: a module and a script reach the suites that call and run them" \
    "test/test_install_runtime_setup.py test/test_runtime_setup_batch.ml test/test_server_runtime_setup_actions.ml" \
    lib/runtime/runtime_setup_spec.ml scripts/install-runtime-setup.py
  check "a file name many files share selects nothing by name" "" \
    "packages/agent_core/lib/dune"
  # Only tool definitions reach the second one; a prompt asset has no first
  # line to fit.
  check "a prompt asset reaches the asset guard and the prompt golden" \
    "test/test_keeper_system_prompt_bytes.ml test/test_managed_assets_sync_from_binary.ml" \
    "config/prompts/foo.md"
  # And not the asset guard: it runs the real sync, whose domains are Prompts,
  # Tools and Mcp. A scheme is embedded but never synced, so that guard has
  # nothing to say about one.
  check "a theme asset reaches the contrast harness" \
    "test/test_tui_theme_contrast.ml" \
    "config/themes/foo.toml"
  check "an edited test is still selected on its own" \
    "test/test_tui_graphics.ml" "test/test_tui_graphics.ml"
  # The hole this closes: the pattern wanted test_ straight after test/, so a
  # suite one directory down was not a "test source this pull request edits".
  check "an edited suite under a test directory is selected too" \
    "test/keeper_chat_operations/test_keeper_chat_operation_store.ml" \
    "test/keeper_chat_operations/test_keeper_chat_operation_store.ml"
  # An interface is the same module: #36279 re-documented this one and the
  # suite over the function it documents did not run.
  check_required "an interface edit selects the suites named after its module" \
    "packages/agent_core/test/test_provider_admission.ml" \
    "packages/agent_core/lib/llm_provider/provider_admission.mli"
  # The third way: the suite's dune stanza links the module. Neither rule
  # above reaches test_tui_theme_contrast from the contrast formula -- the
  # suite is named after what it asserts and opens config/themes, not this
  # source -- and it is the only suite that measures the 53 shipped schemes.
  check "a module its suite links selects that suite" \
    "test/test_tui_theme_contrast.ml" \
    "bin/masc_tui_color.ml"
  # And the cap holds on that rule too. 34 suites link masc_tui_message_layout,
  # so the link says nothing about an edit there and only the suite named
  # after the module is left. Without the cap this answer would be 34 suites.
  # The link mapping still drops this module -- 34 suites link it -- and the
  # module rule selects the suites that call it, which include its own.
  check_required "a module many suites link still reaches the suites that call it" \
    "test/test_tui_markdown.ml test/test_tui_message_layout.ml" \
    "bin/masc_tui_message_layout.ml"
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
  # The harness brings the suite that names it: which scenarios a family
  # holds and which --scenario picks is checked there without a terminal.
  check "an edited terminal scenario is selected" \
    "test/test_tui_keyboard_input.py test/test_tui_keyboard_scenario_selection.py" \
    "test/test_tui_keyboard_input.py"
  # tui_browser names five suites, over the per-module cap, so the name
  # mapping attributes nothing to this interface. What is left is the
  # scenario that declares the path and the one suite whose stanza links the
  # library -- two precise claims where the name was a namespace.
  check "an interface over the cap still reaches two precise claims" \
    "test/test_tui_browser.ml test/test_tui_browser_history.py" \
    "bin/masc_tui_browser.mli"
  check "an interface and its edited PTY suite select one entry" \
    "test/test_tui_browser.ml test/test_tui_browser_history.py" \
    "bin/masc_tui_browser.mli" "test/test_tui_browser_history.py"
  # No dune rule declares an alias for this one, so nothing can run it and
  # selecting it would fail the step on a file that is not a suite.
  check "a .py with no rule of its own selects nothing" "" \
    "test/test_browser_activation.py"

  # The runner, over a stand-in dune that links at once. What these pin is
  # the budget and the build verdicts: a slow suite is stopped at the budget
  # and the suites after it are named, a build the budget cuts off names every
  # suite, and a suite that does not link is the build's failure. The scope
  # and stanza readers are stubbed; their own self-tests cover them.
  write_stand_in_dune() {
    cat > "$1" <<'FAKE'
#!/usr/bin/env bash
# dune build <target>...: writes each executable target. A name holding
# "broken" does not link, "failing" exits 1, "slow" outlasts any budget here.
[ "$1" = build ] || exit 2
shift
sleep "${FAKE_DUNE_BUILD_SECONDS}"
status=0
for target in "$@"; do
  name=$(basename "${target}" .exe)
  case "${name}" in
    *broken*) echo "stand-in dune: ${name} does not link" >&2; status=1; continue ;;
    *slow*) body='exec sleep 60' ;;
    *failing*) body='exit 1' ;;
    *) body='exit 0' ;;
  esac
  mkdir -p "_build/default/$(dirname "${target}")"
  printf '#!/bin/sh\n%s\n' "${body}" > "_build/default/${target}"
  chmod +x "_build/default/${target}"
done
exit "${status}"
FAKE
    chmod +x "$1"
  }
  # Called in a subshell: it moves into a scratch root and repoints the
  # globals run_selected reads.
  runner_failures() {
    local build_seconds="$1" budget="$2"
    local fixture_source source_path
    shift 2
    work=$(mktemp -d)
    trap 'rm -rf "${work}"' EXIT
    mkdir -p "${work}/bin" "${work}/root"
    write_stand_in_dune "${work}/bin/dune"
    printf 'print("run")\n' > "${work}/scope.py"
    : > "${work}/reader.py"
    PATH="${work}/bin:${PATH}"
    export FAKE_DUNE_BUILD_SECONDS="${build_seconds}"
    scope_tool="${work}/scope.py"
    stanza_reader="${work}/reader.py"
    repo_root="${work}/root"
    cd "${repo_root}"
    sources=""
    for fixture_source in "$@"; do
      case "${fixture_source}" in
        */*.ml | */*.py) source_path="${fixture_source}" ;;
        *) source_path="test/${fixture_source}.ml" ;;
      esac
      sources=$(printf '%s\n%s\n' "${sources}" "${source_path}")
    done
    direct_sources="${RUNNER_DIRECT_SOURCES:-}"
    budget_seconds="${budget}"
    SECONDS=0
    run_selected > /dev/null 2>&1
    # The seconds a stopped suite was given depend on where the clock stood.
    printf '%b' "${failed}" | sed -E 's/ after [0-9]+s\)/)/' | tr '\n' ';'
  }
  runner_check() {
    local label="$1" want="$2"
    shift 2
    local got
    got=$(runner_failures "$@")
    if [ "${got}" = "${want}" ]; then
      echo "ok   ${label}"
    else
      echo "FAIL ${label}"
      echo "     want: ${want:-<nothing>}"
      echo "     got:  ${got:-<nothing>}"
      failures=$((failures + 1))
    fi
  }
  runner_check "suites within the budget all run" "" 0 30 \
    test_ok test_ok_too
  runner_check "the budget stops a slow suite and names the suites after it" \
    "test/test_broken (build);test/test_failing (run);test/test_slow (stopped at the step budget);test/test_zz_after (not run: the step budget ran out);" \
    0 3 test_ok test_broken test_failing test_slow test_zz_after
  RUNNER_DIRECT_SOURCES="test/test_zz_direct_failing.ml" \
    runner_check "a directly edited suite runs before attributed suites spend the budget" \
      "test/test_zz_direct_failing (run);test/test_aa_slow (stopped at the step budget);" \
      0 3 test_aa_slow test_zz_direct_failing
  RUNNER_DIRECT_SOURCES="test/test_zz_direct_broken.py" \
    runner_check "a directly edited Python rule runs before attributed linked suites" \
      "test/test_zz_direct_broken (run);test/test_aa_slow (stopped at the step budget);" \
      0 3 test_aa_slow test/test_zz_direct_broken.py
  # The build starts with budget left and outlasts it, so the timeout on the
  # build is what ends it. With a one-second budget the budget was already
  # spent before the build began, and that case passed without the timeout.
  runner_check "a build the budget cuts off names every suite" \
    "test/test_ok (not built: the step budget ran out);test/test_failing (not built: the step budget ran out);" \
    8 3 test_ok test_failing

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

run_selected

echo "ran ${ran}, skipped ${skipped}"

if [ -z "${failed}" ]; then
  exit 0
fi

echo "suites that did not pass:"
printf '  %b' "${failed}"
exit 1
