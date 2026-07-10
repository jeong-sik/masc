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
#   run-lint-suite.sh blocking            # every always-on blocking lint
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

blocking_lints() {
  run_lint "Hardcoded model prefix" bash scripts/lint/no-roadmap-stale-hardcoding.sh
  run_lint "Raw font-size px" bash scripts/lint/no-raw-font-size-px.sh
  run_lint "OCaml comment terminator trap" bash scripts/lint/no-ocaml-comment-terminator-trap.sh
  run_lint "Timeout env knob ceiling (RFC-0138)" bash scripts/lint/timeout-env-ceiling.sh
  run_lint "No actionable-signal bool context" bash scripts/lint/no-actionable-signal-bool-context.sh
  run_lint "Provider name hardcoding ratchet" bash scripts/lint/no-provider-name-hardcoding.sh --fail
  run_lint "Keeper behavior hardcoding" bash scripts/lint/no-keeper-behavior-hardcoding.sh
  run_lint "Eval tool-selector runtime import" bash scripts/lint/no-eval-tool-selector-runtime-import.sh
  run_lint "Legacy tool surface name" bash scripts/lint/no-legacy-tool-surface-name.sh --fail
  run_lint "Retired tool husk ratchet" bash scripts/lint/no-retired-tool-husks.sh --fail
  run_lint "Synthetic tool-call residue ratchet" bash scripts/lint/no-synthetic-tool-call-residue.sh --fail
  run_lint "Tool substrate adapter surface" bash scripts/lint/no-tool-substrate-adapter-surface.sh --fail
  run_lint "Tool -> Keeper dependency-direction ratchet (RFC-0194)" bash scripts/lint/tool-keeper-boundary-ratchet.sh --fail
  run_lint "MASC domain ownership ratchet" bash scripts/lint/masc-domain-boundary-ratchet.sh --fail
  run_lint "No Tool_result.error + Printexc (RFC-0148)" bash scripts/lint/no-tool-result-error-printexc.sh
  run_lint "Boundary redaction SSOT (RFC-0132 PR-3)" bash scripts/lint/no-runtime-literal-outside-boundary-redaction.sh --fail
  run_lint "No fabricated telemetry" bash scripts/lint/no-fabricated-telemetry.sh
  run_lint "No oas_* prefix in lib/ (RFC-0047)" bash scripts/lint/no-oas-prefix-in-lib.sh
  run_lint "No inline ok-envelope literals" bash scripts/lint/no-inline-ok-envelope.sh
  run_lint "No inline error-envelope literals" bash scripts/lint/no-inline-error-envelope.sh
  run_lint "No inline json_kind_name" bash scripts/lint/no-inline-json-kind-name.sh
  run_lint "No yojson 3.0 dead arms" bash scripts/lint/no-yojson-3-dead-arms.sh
  run_lint "Workflow YAML syntax" bash scripts/lint/yaml-syntax.sh
  run_lint "Board SLO extractor fixture" bash scripts/test-board-slo-extractor.sh
  run_lint "Spawn-bounded ratchet" bash scripts/lint-spawn-bounded.sh
  run_lint "audit-path-ssot" bash scripts/audit-path-ssot.sh
}

blocking_pr_lints() {
  local base="$1"
  run_lint "Env knob classification" \
    python3 scripts/ci/check-env-knob-classification.py --base "${base}" --head HEAD
  run_lint "Fun.protect finalizer guard" \
    python3 scripts/ci/check-fun-protect-finally-guard.py --base "${base}" --head HEAD
  run_lint "ignore() justification (new sites)" \
    bash scripts/ci/check-ignore-without-comment-diff.sh --base "${base}" --head HEAD
  run_lint "Stale-base revert guard self-test (RFC-0235)" \
    python3 scripts/ci/test_check_stale_base_revert.py
  run_lint "Stale-base revert guard (RFC-0235)" \
    python3 scripts/ci/check-stale-base-revert.py --base "${base}" --head HEAD
}

advisory_lints() {
  run_lint "Dashboard env knob count (advisory)" bash scripts/lint-timeout-env-count.sh --strict
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
