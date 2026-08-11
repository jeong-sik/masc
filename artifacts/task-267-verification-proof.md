# task-267 verification proof

## Change

- `.github/workflows/ci.yml` establishes `CI_TEST_DEADLINE_EPOCH` at the start of the 60-minute Build and Test job.
- The focused runner reserves 600 seconds for the transport and contract harnesses, caps each serial group by the remaining shared budget, and exits 124 before starting later groups after the budget is exhausted.
- Transport and contract harnesses each receive `CI_TEST_TIMEOUT_SEC=300`.
- `scripts/ci-run-tests.sh` caps command and contract-harness execution at the absolute job deadline and emits deadline-specific diagnostics.

## Verification

- `bash -n scripts/ci-run-tests.sh` — pass.
- `bash -n scripts/ci-run-focused-tests.sh` — pass.
- `ruby -e "require 'yaml'; YAML.load_file('.github/workflows/ci.yml')"` — pass.
- `git diff --check` — pass.
- `bash scripts/dune-local.sh exec test/test_ci_run_tests_script.exe` — 6/6 pass, including the job-deadline termination regression.
- `CI_FOCUSED_SUITE_BUDGET_SEC=0 CI_FOCUSED_SUITE_RESERVE_SEC=0 bash scripts/ci-run-focused-tests.sh` — exits 124 before launching a group, with the focused-suite deadline diagnostic.

`ci-run-tests.sh` shellcheck reports only the two pre-existing findings at lines 159 and 211 (SC2009 and SC2235); the focused runner reports no findings.
