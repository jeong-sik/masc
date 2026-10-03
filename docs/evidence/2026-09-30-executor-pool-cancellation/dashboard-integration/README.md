# Dashboard request cancellation — local integration evidence

Both regression cases link the actual `masc.dashboard` library and call
`Dashboard_cache.get_or_compute_payload_with_timeout`. No Dashboard module
substitute or production server was used.

| Measurement | Raw files | Result |
|---|---|---|
| Original executor body with the new tests | dashboard-red-build.json/log | build exit 0 |
| Request timeout with original executor body | dashboard-red.json/log | exit 2; both fill and lazy-payload cases FAIL |
| Restored executor implementation | dashboard-restored-build.json/log | build exit 0 |
| Request timeout with restored implementation | dashboard-restored-green.json/log | exit 0; both cases pass |

The RED log shows the timeout envelope assertion succeeding before the worker
stop assertion fails. Both test cases fail in this control; restoring only
`Executor_pool_ref.submit_or_inline` makes both pass. RED used the executor
body from base `04256f2b1d`; the test module and Dune declaration hashes are
identical in the RED and GREEN receipts. The public interface was unchanged.

The two cases independently cover cache fill and lazy HTTP payload preparation.
They check cancellation reaches a suspended worker, no replay occurs inline,
no interrupted payload is published, the existing lazy JSON AST is retained,
a subsequent request recovers, and its raw JSON and ETag remain consistent.
Cleanup releases suspended workers even when the intended assertion fails.

Reproduce from the worktree:

```sh
env -u MASC_CONFIG_DIR -u MASC_BASE_PATH bash scripts/dune-local.sh build test/test_dashboard_cache_cancellation.exe
env -u MASC_CONFIG_DIR -u MASC_BASE_PATH _build/default/test/test_dashboard_cache_cancellation.exe
```

`run.py` is the exact local receipt runner, invoked from the Keeper playground
with a unique label and the command above. It records UTC boundaries, command,
source hashes, exit code and original process output without overwriting logs.
It sets `MASC_SKIP_DEPS_CHECK=1` because installed DOS/MSX pins differ; shared
pins were not changed. The focused library and executable compiled successfully.
`source-hashes.txt` also binds the unchanged Dashboard implementation and public
interfaces read after the restored run. `SHA256SUMS` covers the packaged files.

Cancellation remains cooperative; CPU loops and blocking calls that never
suspend cannot be forcibly interrupted by this change. Full repository builds,
CI dispatch, full-suite execution and installed-server saturation were not run.
The earlier qrc-blocked shared suite is retained in the parent evidence folder;
the new focused target removes that unrelated test-link dependency.

[근거] Original local process output and JSON receipts, 2026-09-30
11:44:22–11:44:35 UTC; High for these two integration paths, unverified for
installed-server behavior and release acceptance.
