# Executor pool caller cancellation — #36496

## Result

Caller cancellation now signals the offloaded Eio computation through
`Executor_pool_ref.submit_or_inline`. The running-worker regression fails
with the original function and passes with the patch. Cancellation remains
cooperative: an Eio suspension is interruptible; a CPU loop or blocking system
call that never yields is not forcibly terminated.

This is local component evidence, not installed-server or merge acceptance.

## Sources and measurements

- Tested source commit after rebase: `0f175c676d7dd1427fb70baa71bc48825e9a778e`.
- Rebase base: `04256f2b1d`.
- Exact source SHA-256 values, command, environment, UTC start/end and exit code
  are in each JSON receipt; the adjacent log is the original process output.
- RED uses the unmodified `submit_or_inline` body from
  `3e22dc273c42e555efb4e38e6cf06b8da49323e3`. Test sources and the public
  interface are unchanged across RED and GREEN. The implementation hash
  changes from `385cef4be600688de00009f728b4801d72d8a55e1d8e12be027141d16d20d03e`
  to `be205df02e6383ea02aec4708191d2a216554f0e08d8a0045fd895ae4d2cc07a`.

| Claim | Receipt | Result |
|---|---|---|
| Baseline compiles with new component tests | core-red-build.json/log | exit 0 |
| Baseline leaves a suspended worker running | core-red.json/log | exit 1, running-worker assertion false; other two controls pass |
| Restored implementation | core-restored-build.json/log and core-restored-green.json/log | build 0; 3/3 pass |
| Latest rebase has the same tested sources | rebased-core-build.json/log and rebased-core-green.json/log | build 0; 3/3 pass |
| New test module is wired and cases registered | test-wiring.json/log and test-functions.json/log | both exit 0 |
| Dashboard cache suite | rebased-dashboard-build.json/log | blocked before compilation: missing qrc |
| Small actual-Dashboard link attempt | cache-probe-build.json/log | stopped at the local runner's 50-second limit, no binary or test result |

The three component cases cover running-worker cancellation without replay,
withdrawal while waiting for capacity, and successful nested/inline calls.
The added Dashboard case covers timed-out fills and lazy payload preparation,
no late cache publication, preservation of an existing JSON AST and recovery.
The Dashboard regression now runs as two independent cases in the focused
`test_dashboard_cache_cancellation.exe` target. Both fail with the original
executor body and pass with the restored patch. The actual `masc.dashboard`
library is linked. Raw logs, exact source hashes and UTC receipts are in
[dashboard-integration/README.md](dashboard-integration/README.md).

## Reproduction

From the worktree, with the required dependencies installed:

```sh
env -u MASC_CONFIG_DIR -u MASC_BASE_PATH bash scripts/dune-local.sh build test/test_executor_pool_cancellation.exe
env -u MASC_CONFIG_DIR -u MASC_BASE_PATH _build/default/test/test_executor_pool_cancellation.exe
env -u MASC_CONFIG_DIR -u MASC_BASE_PATH bash scripts/dune-local.sh build test/test_dashboard_cache_cancellation.exe
env -u MASC_CONFIG_DIR -u MASC_BASE_PATH _build/default/test/test_dashboard_cache_cancellation.exe
```

The recorded local builds set `MASC_SKIP_DEPS_CHECK=1` because the installed
DOS/MSX pins differ from the repository declarations. The focused Core and
Dashboard targets do not depend on those libraries. This does not validate the full repository
toolchain. Shared pins were not changed. Full builds, CI dispatch and production
30-second saturation were not run. Temporary probe files were removed.

[근거] Original process logs and source-bound JSON receipts in this directory;
2026-09-30 10:42–10:49 UTC (component) and 11:44:22–11:44:35 UTC
(Dashboard); High for the tested RED/GREEN paths, unverified for
installed-server behavior.
