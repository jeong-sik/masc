# task-267 verification proof (inspectable)

## Source revision and diff scope

Implementation commit: `c60e6db63ebecb04bb066fa9d67a16542e75a15d` on `sangsu/task-267-ci-deadline`.

```
$ git diff origin/pr-28216...HEAD --stat
.github/workflows/ci.yml                 | 14 +++++
artifacts/task-267-verification-proof.md | 19 +++++++
scripts/ci-run-focused-tests.sh          | 97 ++++++++++++++++++++++++++++----
scripts/ci-run-tests.sh                  | 55 ++++++++++++++++--
test/test_ci_run_tests_script.ml         | 30 ++++++++++
5 files changed, 199 insertions(+), 16 deletions(-)
```

The implementation changes are in the workflow, focused runner, shared CI observer, and its regression test. The proof file is the only later evidence-only update.

## Concrete timeout accounting

`.github/workflows/ci.yml` has `timeout-minutes: 60` at the Build and Test job (line 663). Before setup/compilation, the first step writes:

```yaml
CI_JOB_TIMEOUT_SEC: "3600"
deadline_epoch=$(( $(date +%s) + CI_JOB_TIMEOUT_SEC ))
echo "CI_TEST_DEADLINE_EPOCH=${deadline_epoch}" >> "${GITHUB_ENV}"
```

The focused step passes `CI_FOCUSED_SUITE_RESERVE_SEC: "600"`. The transport and contract steps each pass `CI_TEST_TIMEOUT_SEC: 300`.

Therefore the focused runner's absolute budget is computed from the job deadline, not from focused-step start:

```bash
if [[ -n "${CI_TEST_DEADLINE_EPOCH:-}" ]]; then
  remaining=$((CI_TEST_DEADLINE_EPOCH - $(date +%s) - CI_FOCUSED_SUITE_RESERVE_SEC))
else
  remaining=$((FOCUSED_START_EPOCH + CI_FOCUSED_SUITE_BUDGET_SEC - $(date +%s)))
fi
```

This subtracts all setup/build time already spent. Each requested serial group timeout is capped by `remaining`; when it reaches zero, the runner returns 124 and does not start later groups. The two post-focused harness limits total `300 + 300 = 600` seconds, exactly matching the focused reserve. Thus the absolute job deadline accounts for setup, focused groups, and both harnesses; a group schedule that cannot fit fails closed instead of overrunning the 60-minute job.

The requested focused ceilings remain explicit in `scripts/ci-run-focused-tests.sh`: paused 600s, host-fd 120s, board 180s, normal 1200s, optional agent-core 900s, operator 600s, and SSE 900s. They are ceilings only; the shared absolute budget is authoritative.

## Concrete implementation excerpts

`scripts/ci-run-focused-tests.sh`:

```text
16 export CI_FOCUSED_SUITE_RESERVE_SEC="${CI_FOCUSED_SUITE_RESERVE_SEC:-600}"
17 export CI_FOCUSED_SUITE_BUDGET_SEC="${CI_FOCUSED_SUITE_BUDGET_SEC:-3000}"
42 focused_budget_remaining_sec() {
45   remaining=$((CI_TEST_DEADLINE_EPOCH - $(date +%s) - CI_FOCUSED_SUITE_RESERVE_SEC))
55 focused_timeout_sec() {
59   if [[ "${remaining}" -le 0 ]]; then
61     echo "[ci-focused] ERROR: focused suite budget exhausted; later groups are not started"
62     return 124
64   if [[ "${requested}" -gt "${remaining}" ]]; then
65     printf '%s\\n' "${remaining}"
77 effective_timeout_sec="$(focused_timeout_sec "${timeout_sec}")" || return $?
80 CI_TEST_TIMEOUT_SEC="${effective_timeout_sec}" \\
81   scripts/ci-run-tests.sh "${command}" || status=$?
98 stop_if_focused_budget_exhausted() {
100   echo "::error::focused suite deadline reached before all groups completed"
101   exit 124
}
```

`scripts/ci-run-tests.sh` applies the same absolute deadline to each command and its optional contract harness:

```text
27 TEST_TIMEOUT_SEC="${CI_TEST_TIMEOUT_SEC:-0}"
28 TEST_DEADLINE_EPOCH="${CI_TEST_DEADLINE_EPOCH:-}"
267 if [[ -n "${TEST_DEADLINE_EPOCH}" ]]; then
270   if [[ "${deadline_remaining}" -le 0 ]]; then
272     diag_dump "deadline_exceeded"
274     return 124
276   if [[ "${observed_timeout_sec}" -eq 0 || "${observed_timeout_sec}" -gt "${deadline_remaining}" ]]; then
277     observed_timeout_sec="${deadline_remaining}"
304     diag_dump "job_deadline_timeout_${observed_timeout_sec}s"
```

## Regression and command output

The new regression is `test/test_ci_run_tests_script.ml:178-204`: it sets `CI_TEST_TIMEOUT_SEC=0`, gives the command a three-second absolute deadline, runs a five-second command, and asserts exit 124, the command was started but did not finish, and `job_deadline_timeout_*` diagnostics were emitted.

```text
$ bash scripts/dune-local.sh exec test/test_ci_run_tests_script.exe
[OK] dune command observed once and sanitized
[OK] failure is not retried
[OK] deadline terminates one command
[OK] job deadline terminates one command
[OK] contract harness runs once
[OK] retry layers are absent
Test Successful in 10.946s. 6 tests run.
```

The focused fail-fast path was exercised directly:

```text
$ CI_FOCUSED_SUITE_BUDGET_SEC=0 CI_FOCUSED_SUITE_RESERVE_SEC=0 \\
    bash scripts/ci-run-focused-tests.sh
[ci-focused] ERROR: focused suite budget exhausted; later groups are not started
::error::focused suite deadline reached before all groups completed
$ echo $?
124
```

Additional checks:

```text
$ bash -n scripts/ci-run-tests.sh
$ bash -n scripts/ci-run-focused-tests.sh
$ ruby -e "require 'yaml'; YAML.load_file('.github/workflows/ci.yml'); puts 'ci.yml YAML OK'"
ci.yml YAML OK
$ git diff --check
```

All commands above exited successfully except the intentional budget=0 regression, which exited 124 as required. The focused runner has no shellcheck findings; `ci-run-tests.sh` retains only pre-existing SC2009 and SC2235 informational/style findings.
