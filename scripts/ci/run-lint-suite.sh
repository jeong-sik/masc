#!/usr/bin/env bash
# Consolidated Fundamental Check driver (issue: runner-slot starvation).
#
# Runs executable fixtures, test wiring, syntax, dependency and credential
# checks. Collect failures so one failed command does not hide later results.
#
# Modes:
#   run-lint-suite.sh blocking [BASE]     # every always-on blocking lint
#   run-lint-suite.sh blocking-pr BASE    # additional checks in the PR lane
set -uo pipefail

mode="${1:?usage: run-lint-suite.sh <blocking|blocking-pr> [base-sha] [head-sha]}"
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
  # One path, or several separated by spaces (the checker and its self-test).
  local -a watched
  read -r -a watched <<< "$2"
  shift 2

  # A checker's synthetic fixtures validate the checker implementation, not
  # every product change. Run them when their implementation changes. If the base is
  # unavailable (manual/initial push), fail safe by running the self-test.
  if [[ -n "${base_sha}" && "${base_sha}" != "0000000000000000000000000000000000000000" ]] \
    && git cat-file -e "${base_sha}^{commit}" 2>/dev/null \
    && git diff --quiet "${base_sha}" HEAD -- "${watched[@]}"
  then
    echo "::notice::Skipping ${label}; ${watched[*]} unchanged"
    return
  fi

  run_lint "${label}" "$@"
}

blocking_lints() {
  run_self_test_when_changed "PR check Draft/Ready approval contract" \
    ".github/workflows/pr-check.yml scripts/review/approve-guard.sh scripts/review/approve-guard-selftest.sh scripts/review/pr-check-run-contract.sh scripts/review/fixtures/pr-check-draft-jobs-39834.json" \
    bash scripts/review/approve-guard-selftest.sh --workflow .github/workflows/pr-check.yml
  run_self_test_when_changed "Review queue ledger readiness" \
    "scripts/review/queue-ledger.sh scripts/review/test_queue_ledger.py scripts/review/ci-freshness.py scripts/review/batch_evidence.py scripts/review/review-verdict.sh scripts/review/pr-check-run-contract.sh scripts/review/fixtures/pr-check-draft-jobs-39834.json" \
    python3 scripts/review/test_queue_ledger.py
  run_self_test_when_changed "Review approval and merge boundary" \
    "scripts/review/approve-guard.sh scripts/review/approve-guard-selftest.sh scripts/review/merge-guard.sh scripts/review/ci-checks.sh scripts/review/ci-freshness.py scripts/review/batch_evidence.py scripts/review/review-verdict.sh scripts/review/pr-check-run-contract.sh scripts/review/fixtures/pr-check-draft-jobs-39834.json" \
    bash scripts/review/approve-guard-selftest.sh
  run_self_test_when_changed "Combined-tree batch review evidence" \
    "scripts/review/batch_evidence.py scripts/review/test_batch_evidence.py scripts/review/land-batch.sh scripts/review/ci-freshness.py scripts/review/ci-checks.sh scripts/review/review-verdict.sh scripts/review/approve-guard.sh scripts/review/merge-guard.sh" \
    python3 scripts/review/test_batch_evidence.py
  run_lint "Installer terminal wizard" python3 test/test_installer_wizard.py
  run_lint "Installer upgrade configuration" python3 test/test_installer_upgrade.py
  run_self_test_when_changed "Stagehand probe offline controls" \
    "scripts/stagehand-probe-controls.py scripts/stagehand-probe-manifest.py scripts/test_stagehand_probe_controls.py" \
    python3 scripts/test_stagehand_probe_controls.py
  run_self_test_when_changed "Stagehand extension installer" \
    "connectors/browser/install-stagehand-extension.sh test/test_install_stagehand_extension.sh" \
    bash test/test_install_stagehand_extension.sh
  run_self_test_when_changed "Deployment scripts refuse before touching prod" \
    "scripts/deploy.sh scripts/install-local-build.sh scripts/check-runtime-deployment-preflight.sh test/test_deploy_preflight.sh" \
    bash test/test_deploy_preflight.sh
  run_lint "CHANGELOG has one section for this version" \
    python3 scripts/ci/changelog-section.py \
    "$(sed -n 's/^(version \([0-9.]*\))$/\1/p' dune-project)" CHANGELOG.md /dev/null
  run_lint "Changelog section self-test" python3 test/test_changelog_section.py
  run_lint "Changelog fragments well-formed" \
    python3 scripts/changelog-fragments.py check
  run_lint "Changelog fragments self-test" \
    python3 test/test_changelog_fragments.py
  run_lint "Issue taxonomy parser and reconciliation" node scripts/test-issue-taxonomy-core.cjs
  run_self_test_when_changed "OCaml test suite reporter self-test" \
    scripts/ci-run-test-suite.sh \
    bash scripts/ci-run-test-suite.sh --self-test
  run_lint "Edited-tests selector self-test" \
    bash scripts/ci/run-edited-tests.sh --self-test
  run_self_test_when_changed "Test suites declared as tests self-test" \
    scripts/lint/test-suites-are-declared-as-tests.sh \
    bash scripts/lint/test-suites-are-declared-as-tests.sh --self-test
  run_lint "Test suites declared as tests" \
    bash scripts/lint/test-suites-are-declared-as-tests.sh
  run_self_test_when_changed "Test modules are wired self-test" \
    scripts/lint/test-modules-are-wired.py \
    python3 scripts/lint/test-modules-are-wired.py --self-test
  run_lint "Test modules are wired" \
    python3 scripts/lint/test-modules-are-wired.py
  run_self_test_when_changed "Test functions are registered self-test" \
    scripts/lint/test-functions-are-registered.py \
    python3 scripts/lint/test-functions-are-registered.py --self-test
  run_lint "Test functions are registered" \
    python3 scripts/lint/test-functions-are-registered.py
  run_self_test_when_changed "Dune suite scope self-test (RFC-0428)" \
    scripts/ci/dune_suite_scope.py \
    python3 scripts/ci/test_dune_suite_scope.py
  run_self_test_when_changed "Referencing suites self-test (RFC-0428)" \
    scripts/ci/referencing_suites.py \
    python3 scripts/ci/test_referencing_suites.py
  run_self_test_when_changed "Test stanza env reader self-test" \
    scripts/ci/stanza_env.py \
    python3 scripts/ci/stanza_env.py --self-test
  run_lint "Test stanza env is readable" \
    python3 scripts/ci/stanza_env.py --check-all
  run_self_test_when_changed "Shim stub set agrees self-test" \
    scripts/lint/shim-stub-set-agrees.sh \
    bash scripts/lint/shim-stub-set-agrees.sh --self-test
  run_lint "Shim stub set agrees" bash scripts/lint/shim-stub-set-agrees.sh --fail
  run_lint "Opam cache freshness ratchet" bash scripts/ci/opam-cache-freshness.sh --check
  run_self_test_when_changed "Opam cache freshness self-test" \
    scripts/ci/opam-cache-freshness.sh \
    bash scripts/ci/opam-cache-freshness.sh --self-test
  run_lint "Workflow YAML syntax" bash scripts/lint/yaml-syntax.sh
  run_self_test_when_changed "Workflow skip propagation self-test" \
    "scripts/ci/check-workflow-skip-propagation.py" \
    python3 scripts/ci/check-workflow-skip-propagation.py --self-test
  run_lint "Workflow skip propagation" python3 scripts/ci/check-workflow-skip-propagation.py
  run_lint "Board SLO extractor fixture" bash scripts/test-board-slo-extractor.sh
  run_lint "TUI graceful restart fixture" env TUI_GRACEFUL_RESTART_SELF_TEST=1 bash scripts/tui-graceful-restart.sh
  run_lint "TUI graceful restart, one real cycle" bash scripts/test-tui-graceful-restart-e2e.sh
  run_lint "Feedback-loop metrics fixture" bash scripts/test-feedback-loop-metrics.sh
  run_lint "Stale-worktree cleanup keeps commits" bash scripts/test-cleanup-stale-worktrees.sh
  run_lint "TLA cfg has a parent spec" bash scripts/audit-tla-cfg-orphan.sh
}

blocking_pr_lints() {
  run_lint "Dashboard backend-coupled test detector self-test" \
    python3 scripts/ci/list-dashboard-backend-coupled-tests.py --self-test
  run_lint "Node alias target reader self-test" \
    python3 scripts/ci/list-node-alias-targets.py --self-test
  run_self_test_when_changed "Committed-credential self-test" \
    scripts/ci/check-committed-secrets.py \
    python3 scripts/ci/test_check_committed_secrets.py
  run_lint "No committed credentials" python3 scripts/ci/check-committed-secrets.py
  run_lint "TOML syntax" bash scripts/check-toml-syntax.sh
  run_lint "YAML syntax" python3 scripts/ci/check-yaml-syntax.py
  run_lint "Sandbox dune version" bash scripts/check-sandbox-dune-version.sh
  run_lint "Sandbox OCaml version" bash scripts/check-sandbox-ocaml-version.sh
  run_lint "TLA harness coverage" bash scripts/ci/check-tla-harness-coverage.sh
  run_lint "Opam lock covers declared deps" \
    bash scripts/check-opam-lock-covers-deps.sh
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
    blocking_pr_lints
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
