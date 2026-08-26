#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${repo_root}/.github/workflows/ci.yml"
fundamental="${repo_root}/.github/workflows/fundamental-check.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

step_body() {
  local name="$1"
  awk -v marker="      - name: ${name}" '
    $0 == marker { in_step = 1 }
    in_step && $0 ~ /^      - name: / && $0 != marker { exit }
    in_step { print }
  ' "${workflow}"
}

assert_non_pr_only() {
  local name="$1"
  local body
  body="$(step_body "${name}")"
  [[ -n "${body}" ]] || fail "missing CI step: ${name}"
  grep -Fq "github.event_name != 'pull_request'" <<<"${body}" \
    || fail "expensive PR step is not non-PR-only: ${name}"
  echo "ok: ${name} is outside the PR gate"
}

grep -Fq 'opam exec -- dune build --root . @default @check @install &' "${workflow}" \
  || fail "compile authority disappeared from the PR gate"
echo "ok: compile truth remains required"

[[ ! -e "${repo_root}/.github/workflows/ocamlformat.yml" ]] \
  || fail "formatter-only PR runner returned"
grep -Fq 'bash scripts/ci/run-lint-suite.sh blocking-pr' "${workflow}" \
  || fail "consolidated PR lint authority is missing from ci.yml"
grep -Fq '  pull_request:' "${fundamental}" \
  && fail "Fundamental Check still starts duplicate PR runners"
echo "ok: disabled formatter runner is gone and blocking lint reuses CI"

# shellcheck disable=SC2016
grep -Fq 'if [ "$live_state" = "OPEN" ] && [ "$live_is_draft" = "false" ]; then' "${workflow}" \
  || fail "draft PRs can still start the expensive gate"
echo "ok: only Ready open PRs start compile validation"

for step in \
  "Install grpcurl" \
  "Run source quickstart onboarding smoke" \
  "Run typed functional-core boundary audit" \
  "Run runtime deployment preflight self-test" \
  "Check keeper event queue projection boundary" \
  "Library boundaries against resolved Dune graphs" \
  "Run workspace backlog revision ratchet" \
  "Run the OCaml test suite" \
  "Run transport harness suite" \
  "Run contract harness suite" \
  "Config diagnostic drift report"
do
  assert_non_pr_only "${step}"
done

lifecycle="$(step_body "Verify Keeper full-lifecycle evidence bundle")"
[[ -n "${lifecycle}" ]] || fail "missing lifecycle evidence step"
grep -Fq "github.event_name == 'pull_request'" <<<"${lifecycle}" \
  && fail "lifecycle evidence returned to the PR gate"
echo "ok: lifecycle evidence stays on trusted non-PR lanes"

grep -Fq '  tla-specs:' "${workflow}" \
  && fail "PR CI still owns TLA model checking"
grep -Fq 'TLA_RESULT' "${workflow}" \
  && fail "CI Gate still waits on PR TLA"
echo "ok: TLA ownership stays in tla-main.yml"

echo "PR critical-gate wiring fixture: all cases passed"
