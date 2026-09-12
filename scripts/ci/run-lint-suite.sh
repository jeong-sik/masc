#!/usr/bin/env bash
# Consolidated Fundamental Check driver (issue: runner-slot starvation).
#
# Previously each lint below was its own GitHub Actions job: ~30 jobs x
# (checkout + apt setup) per PR event burned runner slots and queued whole
# PRs for tens of minutes. This driver runs the same scripts sequentially
# in ONE job, but does NOT stop at the first failure: every lint runs,
# failures are collected, and the job fails at the end with the full list —
# preserving the old "see all failures at once" property.
#
# Modes:
#   run-lint-suite.sh blocking [BASE]     # every always-on blocking lint
#   run-lint-suite.sh blocking-pr BASE    # + PR-only diff guards vs BASE
#   run-lint-suite.sh advisory            # non-blocking lints (job uses
#                                         # continue-on-error)
set -uo pipefail

mode="${1:?usage: run-lint-suite.sh <blocking|blocking-pr|advisory> [base-sha]}"
base_sha="${2:-}"

failures=()
ran=0

run_lint() {
  local label="$1"
  shift
  ran=$((ran + 1))
  echo "::group::${label}"
  if "$@"; then
    echo "::endgroup::"
  else
    local status=$?
    echo "::endgroup::"
    echo "::error title=Lint failed::${label} (exit ${status})"
    failures+=("${label}")
  fi
}

run_self_test_when_changed() {
  local label="$1"
  local script="$2"
  shift 2

  # A checker's synthetic fixtures validate the checker implementation, not
  # every product change. Run them when the checker changes; the real checks
  # remain owned by ci.yml's Meta Guards on every heavy CI run. If the base is
  # unavailable (manual/initial push), fail safe by running the self-test.
  if [[ -n "${base_sha}" && "${base_sha}" != "0000000000000000000000000000000000000000" ]] \
    && git cat-file -e "${base_sha}^{commit}" 2>/dev/null \
    && git diff --quiet "${base_sha}" HEAD -- "${script}"
  then
    echo "::notice::Skipping ${label}; ${script} is unchanged"
    return
  fi

  run_lint "${label}" "$@"
}

blocking_lints() {
  run_lint "Installer terminal wizard" python3 test/test_installer_wizard.py
  run_lint "Installer upgrade configuration" python3 test/test_installer_upgrade.py
  run_lint "Issue taxonomy truth" bash scripts/check-issue-taxonomy-truth.sh
  run_lint "Logging consistency" bash scripts/ci/check-logging-consistency.sh
  run_lint "Issue taxonomy parser and reconciliation" node scripts/test-issue-taxonomy-core.cjs
  run_self_test_when_changed "OCaml test suite reporter self-test" \
    scripts/ci-run-test-suite.sh \
    bash scripts/ci-run-test-suite.sh --self-test
  # The three words a prompt's source can be, on both sides of the wire.
  # They are asserted only in test/, which this CI does not run, so a typo in
  # prompt_source_to_string type-checks and passes every other lint while
  # breaking the dashboard's filter and the TUI's label.
  # The selector that decides which suites a pull request runs. Its fixtures
  # are changed-file lists, so they answer in a second and do not need the
  # GitHub API; the mapping they pin is what #34247 slipped past.
  # Not run_self_test_when_changed, unlike its neighbours. The rationale there
  # is that a checker's fixtures are synthetic, so only the checker changing
  # can change the answer. This one's fixtures are not: they name real files
  # under test/, and the mapping resolves them with ls at run time. Adding a
  # suite changes the correct answer without touching this script, which is
  # how both MSX fixtures came to name two suites while test_tui_msx_tick.ml
  # existed -- red on main, and only seen when #34637 edited the script for
  # another reason. It costs about a second.
  run_lint "Edited-tests selector self-test" \
    bash scripts/ci/run-edited-tests.sh --self-test
  run_self_test_when_changed "Prompt source words self-test" \
    scripts/lint/prompt-source-words-agree.sh \
    bash scripts/lint/prompt-source-words-agree.sh --self-test
  run_lint "Prompt source words agree" \
    bash scripts/lint/prompt-source-words-agree.sh

  # Both gates read source text only, so they belong in the blocking suite.
  # Until this change nothing ran either of them: the wiring checker's name
  # pattern did not include the word "gate".
  run_lint "Keeper host_cwd leak gate" \
    bash scripts/keeper-cwd-leak-gate.sh
  run_self_test_when_changed "Turn-path provider-agnostic self-test" \
    scripts/turn-path-provider-agnostic-gate.sh \
    bash scripts/turn-path-provider-agnostic-gate.sh --self-test
  run_lint "Turn-path provider-agnostic gate" \
    bash scripts/turn-path-provider-agnostic-gate.sh

  # A nocheck'd test file keeps compiling after the type its fixture builds has
  # changed shape, so the fixture drifts silently. One did: see the script.
  run_self_test_when_changed "Dashboard tests type-checked self-test" \
    scripts/lint/dashboard-tests-are-type-checked.sh \
    bash scripts/lint/dashboard-tests-are-type-checked.sh --self-test
  run_lint "Dashboard tests type-checked" \
    bash scripts/lint/dashboard-tests-are-type-checked.sh

  # An (executable) named test_* is linked by @check and run by nothing.
  run_self_test_when_changed "Test suites declared as tests self-test" \
    scripts/lint/test-suites-are-declared-as-tests.sh \
    bash scripts/lint/test-suites-are-declared-as-tests.sh --self-test
  run_lint "Test suites declared as tests" \
    bash scripts/lint/test-suites-are-declared-as-tests.sh

  # The report-only step that runs a pull request's edited suites trusts this
  # tool to say which of them can be run by executing the binary. A wrong
  # "run" reports a failure the change did not cause, which is how a report
  # stops being read (RFC-0428).
  run_self_test_when_changed "Dune suite scope self-test (RFC-0428)" \
    scripts/ci/dune_suite_scope.py \
    python3 scripts/ci/test_dune_suite_scope.py
  # test.yml's targeted path runs a suite's executable outside dune, so the
  # stanza's (setenv ...) does not apply and has to be read out. A stanza this
  # reader cannot parse would otherwise surface as a dispatch that ran the
  # suite under an environment nobody chose.
  run_self_test_when_changed "Test stanza env reader self-test" \
    scripts/ci/stanza_env.py \
    python3 scripts/ci/stanza_env.py --self-test
  run_lint "Test stanza env is readable" \
    python3 scripts/ci/stanza_env.py --check-all
  run_lint "Hardcoded model prefix" bash scripts/lint/no-roadmap-stale-hardcoding.sh
  run_lint "Raw font-size px" bash scripts/lint/no-raw-font-size-px.sh
  run_lint "Harness connector env ratchet (#28807)" \
    bash scripts/lint/harness-connector-env-ratchet.sh --self-test
  run_lint "OCaml comment terminator trap" bash scripts/lint/no-ocaml-comment-terminator-trap.sh
  run_lint "Wire-field removal schema gate (#29516/#29601/#29666)" \
    bash scripts/wire-field-removal-schema-gate-selftest.sh
  run_lint "Timeout env knob ceiling (RFC-0138)" bash scripts/lint/timeout-env-ceiling.sh
  run_self_test_when_changed ".mli env knob exists self-test" \
    scripts/lint/mli-env-knob-exists.sh \
    bash scripts/lint/mli-env-knob-exists.sh --self-test
  run_lint ".mli env knob exists" bash scripts/lint/mli-env-knob-exists.sh --fail
  run_self_test_when_changed "Guard scan targets exist self-test" \
    scripts/lint/guard-scan-targets-exist.sh \
    bash scripts/lint/guard-scan-targets-exist.sh --self-test
  run_lint "Guard scan targets exist" bash scripts/lint/guard-scan-targets-exist.sh --fail
  run_self_test_when_changed "Shim stub set agrees self-test" \
    scripts/lint/shim-stub-set-agrees.sh \
    bash scripts/lint/shim-stub-set-agrees.sh --self-test
  run_lint "Shim stub set agrees" bash scripts/lint/shim-stub-set-agrees.sh --fail
  run_lint "Opam cache freshness ratchet" bash scripts/ci/opam-cache-freshness.sh --check
  run_self_test_when_changed "Opam cache freshness self-test" \
    scripts/ci/opam-cache-freshness.sh \
    bash scripts/ci/opam-cache-freshness.sh --self-test
  run_lint "No actionable-signal bool context" bash scripts/lint/no-actionable-signal-bool-context.sh
  run_lint "Provider name hardcoding ratchet" bash scripts/lint/no-provider-name-hardcoding.sh --fail
  run_lint "Keeper behavior hardcoding" bash scripts/lint/no-keeper-behavior-hardcoding.sh
  run_lint "Eval tool-selector runtime import" bash scripts/lint/no-eval-tool-selector-runtime-import.sh
  run_lint "One process manager in lib" bash scripts/lint/one-process-manager.sh
  run_lint "Legacy tool surface name" bash scripts/lint/no-legacy-tool-surface-name.sh --fail
  run_lint "Retired tool husk ratchet" bash scripts/lint/no-retired-tool-husks.sh --fail
  run_lint "Synthetic tool-call residue ratchet" bash scripts/lint/no-synthetic-tool-call-residue.sh --fail
  run_lint "Tool substrate adapter surface" bash scripts/lint/no-tool-substrate-adapter-surface.sh --fail
  run_lint "Tool -> Keeper dependency-direction ratchet (RFC-0194)" bash scripts/lint/tool-keeper-boundary-ratchet.sh --fail
  run_lint "MASC domain ownership ratchet" bash scripts/lint/masc-domain-boundary-ratchet.sh --fail
  run_self_test_when_changed "Keeper turn content boundary self-test" \
    scripts/check-keeper-turn-content-boundary.sh \
    bash scripts/check-keeper-turn-content-boundary.sh --self-test
  run_lint "No Tool_result.error + Printexc (RFC-0148)" bash scripts/lint/no-tool-result-error-printexc.sh
  run_self_test_when_changed "Board attention exact-flow boundary self-test" \
    scripts/check-board-attention-exact-flow-boundary.sh \
    bash scripts/check-board-attention-exact-flow-boundary.sh --self-test
  run_lint "Boundary redaction SSOT (RFC-0132 PR-3)" bash scripts/lint/no-runtime-literal-outside-boundary-redaction.sh --fail
  run_lint "No fabricated telemetry" bash scripts/lint/no-fabricated-telemetry.sh
  run_lint "No inline ok-envelope literals" bash scripts/lint/no-inline-ok-envelope.sh
  run_lint "Tool-subject key lists mirror each other" bash scripts/lint/subject-keys-mirror.sh
  run_lint "No inline error-envelope literals" bash scripts/lint/no-inline-error-envelope.sh
  run_lint "No inline json_kind_name" bash scripts/lint/no-inline-json-kind-name.sh
  run_lint "No yojson 3.0 dead arms" bash scripts/lint/no-yojson-3-dead-arms.sh
  run_lint "Workflow YAML syntax" bash scripts/lint/yaml-syntax.sh
  run_lint "Board SLO extractor fixture" bash scripts/test-board-slo-extractor.sh
  run_lint "Feedback-loop metrics fixture" bash scripts/test-feedback-loop-metrics.sh
  # A guard nobody runs is a document. Twice a guard sat red on untouched main
  # because nothing reached it -- the cancel-guard lint and
  # check-tui-render-purity.sh -- and a sweep on 2026-09-07 found four more in
  # the same state. This asks the question those answered too late: is every
  # check script reached from something CI runs. It reads no diff base, so it
  # belongs here rather than beside the PR-only guards.
  # Ten guards this repository already wrote and no workflow reached. Each was
  # run on untouched main on 2026-09-07 and passed, which is the cheapest
  # moment to wire one: nothing to fix first, and the next time it goes red
  # somebody sees it. Together they take about 10s of the job.
  #
  # check-boundary-guard-mli-pairs.sh is deliberately not here. It reads a
  # diff against origin/main itself rather than taking a base, so where it
  # belongs is a question this change does not answer (#34018).
  run_lint "Agent-core package shape" bash scripts/check-agent-core-boundary.sh
  run_lint "Execute async surface" bash scripts/check-execute-async-surface.sh
  run_lint "HITL exact-flow boundary" bash scripts/check-hitl-exact-flow-boundary.sh
  run_lint "Turn-records envelope parity" bash scripts/check-turn-records-envelope-parity.sh
  run_lint "Feature flag consistency" bash scripts/check-feature-flag-consistency.sh
  run_lint "Drain loops yield" bash scripts/ci/check-drain-loop-yields.sh
  run_lint "Log severity anti-patterns" bash scripts/ci/check-log-severity-anti-patterns.sh
  run_lint "Determinism contract" bash scripts/ci/check-determinism-contract.sh
  run_lint "TLA variant sync" bash scripts/ci/check-tla-variant-sync.sh
  # Two of the twenty-two audit-* scripts the name pattern used to skip. Both
  # green on main and both proven to fail: an orphan .cfg under specs/ trips
  # the first, an OCaml constructor the TLA set does not carry trips the
  # second. --check-cross-spec is opt-in and nothing was opting in, so the
  # three cross-spec sets it compares were compared nowhere.
  # #32511 replaced the nine-job lane with one manual job. One step it deleted
  # was "Meta bug-class gates (SSOT, SIL, STR, BND)", nine guards run together
  # (#9516 #9517 #9519 #9521). Of those nine: two scripts no longer exist,
  # check_model_prefix_inheritance is above, check_exact_field_decoder_preflight
  # is red (#34018), and these five are green. Each was proven to fail by
  # injection -- a spawn_config_of_key reference, a try ignore (, a docs/spec
  # page naming a missing file, a Mirrors: pointing nowhere, and for the env
  # floor by having been red until #34056.
  run_lint "SSOT spawn drift" bash scripts/ci/check-ssot-spawn-drift.sh
  run_lint "Silent failure patterns" \
    bash scripts/ci/check-silent-failure-patterns.sh
  run_lint "Spec Mirrors: references resolve" bash scripts/check-spec-truth.sh
  run_lint "docs/spec names files that exist" \
    python3 scripts/ci/check-spec-file-refs.py
  # --self-test only, which is what the deleted step ran too: the real check
  # shells out to `dune describe` and this job has no OCaml toolchain. It runs
  # in the dune build @check job instead, where the switch is already built.
  run_lint "Env-read config floor self-test" \
    python3 scripts/ci/check_env_reads_below_config.py --self-test

  # Both were red on main until today, which is the proof they can fail:
  # audit-path-ssot for one expanduser site (#34080), audit-odoc-refs for two
  # references its own field pattern could not resolve (#34081).
  # The last of the nine. It was red until #34106 showed the red was the
  # guard's: keeper meta carries the fields, and keeper_meta_store reads them.
  run_lint "Exact-field decoders have a preflight" \
    python3 scripts/ci/check_exact_field_decoder_preflight.py
  # Named only by a comment in the root dune until now, and red the whole
  # time: half of it asserted a nine-job lane #32511 deleted. That half is
  # gone; what runs here is the half the root dune's comment claims.
  run_lint "Root dune warning mask" \
    bash scripts/ci/check-ocaml-compile-authority.sh
  run_lint "Path layout SSOT" bash scripts/audit-path-ssot.sh
  run_lint "odoc references resolve" python3 scripts/audit-odoc-refs.py
  # The two ratchets that survived #33313, which deleted eighteen nobody ran.
  # Surviving that sweep was a decision to keep them; nothing has called them
  # since. Both are green on main and both proven to fail: hide a -buggy.cfg
  # for the first, take the last [@@deriving tla] out of a file for the second.
  run_lint "TLA bug models keep their pair" bash scripts/tla-bug-model-ratchet.sh
  run_lint "TLA ppx coverage floor" bash scripts/tla-ppx-ratchet.sh
  run_lint "TLA cfg has a parent spec" bash scripts/audit-tla-cfg-orphan.sh
  run_lint "TLA annotation drift" \
    bash scripts/audit-tla-annotation-drift.sh --check-cross-spec
  run_lint "Model prefix inheritance" python3 scripts/ci/check_model_prefix_inheritance.py
  run_lint "Every check script is reached" \
    python3 scripts/ci/check-guards-are-wired.py
}

blocking_pr_lints() {
  local base="$1"
  run_lint "Fun.protect finalizer guard" \
    python3 scripts/ci/check-fun-protect-finally-guard.py --base "${base}" --head HEAD
  run_lint "ignore justification self-test" \
    python3 scripts/test-lint-ignore-without-comment.py
  # The dashboard parity lane runs whatever this detector selects, so a
  # detector that quietly stops matching would empty the lane.
  run_lint "Dashboard backend-coupled test detector self-test" \
    python3 scripts/ci/list-dashboard-backend-coupled-tests.py --self-test
  # Same shape: the build line runs whatever this reader prints, so a reader
  # that stopped matching would drop the browser parity suites again.
  run_lint "Node alias target reader self-test" \
    python3 scripts/ci/list-node-alias-targets.py --self-test
  run_lint "ignore justification (new sites)" \
    bash scripts/ci/check-ignore-without-comment-diff.sh --base "${base}" --head HEAD
  run_lint "Stale-base revert guard self-test (RFC-0235)" \
    python3 scripts/ci/test_check_stale_base_revert.py
  run_lint "Stale-base revert guard (RFC-0235)" \
    python3 scripts/ci/check-stale-base-revert.py --base "${base}" --head HEAD
  # Both do nothing without a base ref, which is why they belong here rather
  # than beside the always-on lints. check-release-train-guard refuses a
  # version downgrade -- 0.33.0 to 0.31.0 in dune-project reports it -- and
  # check-pr-hygiene refuses an empty commit and a Request_priority erasure
  # (#4186), which a planted `~priority:()` reports.
  run_lint "Release train guard" \
    bash scripts/check-release-train-guard.sh --base "${base}" --head HEAD
  run_lint "PR hygiene" bash scripts/check-pr-hygiene.sh --base "${base}"
  # The companion to the boundary guard wired above: a new .mli whose paired
  # .ml is already in that guard's allow-list has to be added alongside it,
  # or every later PR fails on docstrings this one exposed. That is PR #11248
  # -> blocked #11272 -> fix-forward #11280/#11283. Adding a keeper .mli whose
  # .ml is allow-listed, without the .mli, reports PAIR-GATE FAIL.
  run_lint "Boundary-guard .mli pairing" \
    env BASE_REF="${base}" bash scripts/check-boundary-guard-mli-pairs.sh
  # A deleted wire field/variant in a persistence schema is a deploy event,
  # not a refactor: three fleet freezes in one day (#29516/#29601/#29666)
  # came from strict decoders that stopped accepting rows live stores still
  # carry. The removal must ride a version bump, a store strip/migration, or
  # an explicit schema-compat: proof (#29553's rule, now a gate).
  run_lint "Wire-field removal schema gate" \
    env BASE_REF="${base}" bash scripts/wire-field-removal-schema-gate.sh
  # A wildcard catch that swallows Eio.Cancel.Cancelled is the bug this repo
  # modelled in TLA+ (CancelledAbsorbed / CancelledNeverAbsorbed) and hit at
  # runtime as an Assert_failure. The lint existed but no workflow ran it, so
  # the count drifted to 32 and back to 0 without anyone seeing either move.
  # Blocking at 0 keeps the next one from landing unnoticed.
  run_lint "Cancel guard on wildcard catches" bash scripts/lint-cancel-guard.sh
  # A match whose every arm is a bare wildcard computes its scrutinee and
  # throws it away, while reading as if it told two cases apart. Four were in
  # the tree on 2026-09-06 and two of them sat on a real classifier, so the
  # next reader kept looking for a distinction that was not there. Blocking at
  # zero is what stops the fifth.
  run_self_test_when_changed "Wildcard-only match self-test" \
    scripts/ci/check-wildcard-only-match.py \
    python3 scripts/ci/test_check_wildcard_only_match.py
  run_lint "Wildcard-only match" python3 scripts/ci/check-wildcard-only-match.py
  # Drawing a frame is meant to be a function of the state, not a step that
  # edits it. The guard for that was written with a budget of zero and then
  # never run by any workflow, so two modal scroll clamps went back to writing
  # from inside the renderer and main sat red on a check nobody was checking.
  # Same shape as the cancel-guard lint above.
  run_lint "TUI renderer writes no state" bash scripts/ci/check-tui-render-purity.sh
  # Three commits titled "security: remove tracked <secret>" -- #636, #3422,
  # #6487 -- each deleted the file and left the blob served. On 2026-09-07
  # the #636 blob still answered an unauthenticated GitHub blob request, and
  # three of the four Claude tokens in it still authenticated, five months
  # on. GitHub push protection caught the `sk-ant-` key in the task-362
  # capture and let the `postgresql://user:pass@host` line in the same
  # bundle through, because that shape is not one of its provider patterns.
  # Budget is zero against an allowlist that pins fixture values by hash.
  run_self_test_when_changed "Committed-credential self-test" \
    scripts/ci/check-committed-secrets.py \
    python3 scripts/ci/test_check_committed_secrets.py
  run_lint "No committed credentials" python3 scripts/ci/check-committed-secrets.py
  # Six of the guards #34018 listed as unwired, each one measured twice: run
  # on untouched main (passes) and then run again with a violation planted
  # (fails). A guard that only does the first is a guard that passes, which
  # is not the same thing.
  #
  #   check-eio-conventions       Eio_unix.sleep under lib/
  #   audit-ocaml-phase-count     "12-phase" in a keeper comment, SSOT is 8
  #   audit-tla-phase-count       the same drift on the spec side
  #   audit-route-tool-catalog    a route demanding a tool the catalog lacks
  #   audit-shell-ir-consumption  a retired authorization symbol back in lib/
  #   base-policy-audit           `open Base` in an .mli
  #
  # The last two take an argument to enforce anything. Bare, one prints
  # metrics and the other prints a summary, both exiting 0 -- so the name
  # alone would have wired a guard that cannot fail. Three more from that
  # list are staying out for the same reason and the baseline says why.
  run_lint "Eio conventions" bash scripts/check-eio-conventions.sh
  run_lint "OCaml phase-count drift" bash scripts/audit-ocaml-phase-count.sh
  run_lint "TLA phase-count drift" bash scripts/audit-tla-phase-count.sh
  run_lint "Route tool catalog" bash scripts/audit-route-tool-catalog.sh
  run_lint "Shell IR structural boundary" \
    bash scripts/audit-shell-ir-consumption.sh \
    --baseline scripts/shell-ir-consumption-baseline.json
  run_lint "Base policy" bash scripts/base-policy-audit.sh --fail-on-regression
  # The gate itself needs `dune describe` and runs in the build job. This is
  # its self-test, which feeds synthetic graphs and asserts both directions --
  # a clean graph passes, a cycle and a dangling UID are refused -- and needs
  # no switch. Same split as the env-read floor check above.
  run_lint "Sublib leaf boundary self-test" \
    python3 scripts/audit-sublib-cycle.py --self-test
  # Thirteen SSOT rules, each a pattern with a baseline, five of them carrying
  # their own pattern self-tests. It was the last red one on #34018's list and
  # is green now: R2 and R10 were fixed (#34199, #34198), R4 was pointed at
  # three filenames that no longer exist (#34201), and R6 counted 69 prose
  # mentions alongside the one root a program used. 2.7s.
  run_lint "SSOT rules" bash scripts/check-ssot.sh
  # A second pass over #34018's list, this time the entries nobody had ever
  # run. Same method as the six above: run clean, then run again with a
  # violation planted. All seven failed on the planted one.
  #
  #   check-toml-syntax                        an unclosed array in config/
  #   check-yaml-syntax                        the same in a workflow
  #   check-sandbox-dune-version               dune-project asking for more
  #                                            than the sandbox image installs
  #   check-checkpoint-installation-legacy-purge  a retired symbol back in lib/
  #   check-dashboard-nav-event-parity         a section the OCaml allowlist
  #                                            does not carry
  #   check-tla-harness-coverage               a .cfg-backed spec in neither
  #                                            tla-check.sh nor the debt list
  #   check-opam-lock-covers-deps              this one was already failing:
  #                                            ocaml-msx was declared and
  #                                            unlocked, so --locked skipped it
  run_lint "TOML syntax" bash scripts/check-toml-syntax.sh
  run_lint "YAML syntax" python3 scripts/ci/check-yaml-syntax.py
  run_lint "Sandbox dune version" bash scripts/check-sandbox-dune-version.sh
  # Same drift, second toolchain: masc.opam moved to ocaml 5.5.1 in #34143 and
  # the image's switch stayed on 5.5.0, which no workflow builds, so the image
  # was unbuildable for a day before anyone ran the build by hand.
  run_lint "Sandbox OCaml version" bash scripts/check-sandbox-ocaml-version.sh
  run_lint "Checkpoint legacy purge" \
    bash scripts/check-checkpoint-installation-legacy-purge.sh
  run_lint "Dashboard nav-event parity" \
    bash scripts/check-dashboard-nav-event-parity.sh
  # This one also takes scripts/tla-check.sh off the not-wired list, which
  # reads stronger than it is: TLC still runs nowhere. What the gate holds is
  # tla-check.sh's spec list -- a new .cfg-backed spec has to be added to it
  # or written down as debt, rather than appearing checked because no one
  # looked.
  run_lint "TLA harness coverage" bash scripts/ci/check-tla-harness-coverage.sh
  run_lint "Opam lock covers declared deps" \
    bash scripts/check-opam-lock-covers-deps.sh
  # Two more from the same list, both annotated red on 2026-09-07 and both
  # green now -- the annotations go stale, which is its own reason to run
  # them from CI rather than by hand once.
  #
  #   check-keeper-runtime-setting-registry  MASC_KEEPER_PROBE_UNREGISTERED
  #                                          added to env_config_keeper.ml
  #   check-env-snapshot-default-drift       the snapshot's stated 1000 for
  #                                          MASC_CACHE_MAX_ENTRIES against a
  #                                          reader that applies 1000
  run_lint "Keeper runtime setting registry" \
    bash scripts/check-keeper-runtime-setting-registry.sh
  run_lint "Env snapshot default drift" \
    python3 scripts/ci/check-env-snapshot-default-drift.py
  # 30 checks over retired concepts and ownership boundaries, each with its
  # own baseline or forbidden-match list, and no workflow had ever run any of
  # them. Planting "self_correction_required" in lib/ reports
  # V7j-retired-consecutive-tool-failure-guard.
  #
  # 48s, which is most of what this suite costs on its own. Everything else
  # here together is about 60s. Worth it while the alternative is a retired
  # concept walking back in unnoticed, but it is the first place to look if
  # the lint job gets slow.
  # Its own "CI Failure Visibility" section used to be the only thing it
  # confirmed, and it confirmed the absence of a workflow step deleted on
  # purpose in #32511. With that stale check gone the audit passes, so it can
  # run as a gate instead of a report nobody read. It nests
  # anti-fake-audit.sh, which is 113s of its ~120s; the lint job is ~2.5min
  # against a ~6min build in the same PR, so it stays off the critical path.
  run_lint "Hardcoding and truth audit" \
    bash scripts/audit-hardcoding-truth.sh --fail-on-confirmed
  run_lint "Boundary guard" bash scripts/check-boundary-guard.sh
  # Promoted out of the advisory lane. It already ran there with --strict, and
  # --strict is the mode that fails, so the only thing "advisory" bought was
  # that nobody had to look: the count sits exactly at its baseline of 15, and
  # a 16th knob would have been reported and merged. Adding a get_int to the
  # Dashboard module reports it.
  run_lint "Dashboard env knob count" \
    bash scripts/lint-timeout-env-count.sh --strict
  # Green for the first time. It read 11 sites, of which two were the
  # docstring of the module written to replace this anti-pattern -- its
  # exclusion glob said lib/telemetry_observe and the file is at
  # lib/workspace/ -- and one was a comment saying a bare `try ... with _ ->
  # ()` would swallow cancellation. The remaining eight are teardown paths
  # and each now carries its reason on the line.
  run_lint "Silent failure" bash scripts/check_silent_failure.sh --strict
  # A per-pattern ratchet over dashboard/src for Tailwind spellings whose
  # replacement already exists. It was reporting one unit of slack --
  # text-px-literal measured 50 against a baseline of 51 -- which is one free
  # regression, so the baseline moves to 50 in this commit. Planting
  # `text-[13px] bg-zinc-800` reports two patterns over baseline.
  run_lint "Dashboard styling drift" bash scripts/dashboard-drift-check.sh
  # Was listed as a report on the strength of a grep for `exit 1`. It exits 2,
  # and that 2 is the verdict, not a usage error: a dashboard line that names
  # a prompt key config/prompts and prompt_names.ml do not carry decodes to an
  # empty block. Planting 'fusion.judge.probe_absent' on a promptKeys line
  # reports it.
  run_lint "Dashboard prompt keys" bash scripts/audit-dashboard-prompt-keys.sh
  # Two line-reference validators with nothing to validate: no spec preamble
  # and no keeper docstring currently cites a line number. They were written
  # after four citations in a retired queue model drifted 245 to 413 lines
  # while every behavioural claim around them stayed true, so the failure they
  # exist for arrives the moment someone writes the next citation. Wiring them
  # at zero subjects costs a second each and means the first one is checked.
  run_lint "TLA spec line-refs" bash scripts/audit-tla-ml-line-refs.sh
  run_lint "OCaml spec-nav line-refs" \
    bash scripts/audit-ocaml-spec-nav-line-refs.sh
}

advisory_lints() {
  # The two other checks that stay here, with the number that keeps them here. Both have an
  # enforcing mode and both are red in it, so "advisory" is not a policy choice
  # about their subject -- it is where they sit until the count comes down.
  #
  #   lint-magic-number --strict     10 (file, literal) pairs at >= 5 repeats,
  #                                  all ms<->s and KiB conversions. It read 80
  #                                  until #34236 stopped it counting the RFC
  #                                  numbers in its own comments and log lines.
  #   exhaustive-guard BLOCKING=1    826 fragile matches -- checked against
  #                                  comment-stripping, and it is 826 either
  #                                  way; the script's own
  #                                  header says Phase 5 flips this "once the
  #                                  codemod has closed the bulk of inventory
  #                                  and allowlist is narrowed", and 826 is not
  #                                  that
  run_lint "Magic number repetition (advisory)" bash scripts/lint-magic-number.sh
  run_lint "Fragile-match (advisory, RFC-0071 Phase 1)" bash scripts/lint/exhaustive-guard.sh
}

case "${mode}" in
  blocking)
    blocking_lints
    ;;
  blocking-pr)
    if [[ -z "${base_sha}" ]]; then
      echo "::error::blocking-pr mode requires the PR base sha" >&2
      exit 2
    fi
    blocking_lints
    blocking_pr_lints "${base_sha}"
    ;;
  advisory)
    advisory_lints
    ;;
  *)
    echo "::error::unknown mode ${mode}" >&2
    exit 2
    ;;
esac

echo ""
if [[ ${#failures[@]} -gt 0 ]]; then
  echo "FAILED ${#failures[@]}/${ran} lints:"
  printf ' - %s\n' "${failures[@]}"
  exit 1
fi
echo "all ${ran} lints passed"
