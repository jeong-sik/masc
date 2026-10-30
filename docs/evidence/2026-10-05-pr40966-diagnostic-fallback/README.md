# Diagnostic persistence and provider fallback

Baseline PR #40966 head `59fe5af3f9cfe84f179ae2d1946f12fdcfd6896c`.
The actual HTTP fixture verifies the request is durable before primary A receives it, temporarily replaces only the evidence directory with a regular file, and restores it when fallback B is called. The original product fails after A and never reaches B. The repair preserves the diagnostic persistence error in private retained attempt metadata, continues the declared route, and requires B’s answered terminal outcome to be durable. Package responses still contain only sampling evidence references; full provider diagnostics are not embedded.

The first build failed because the new fixture block was inserted into a different callback (`Unbound value store`); this is an authoring error, not behavior RED. The corrected fixture built successfully and produced one meaningful failing test. After the narrow Result match repair, the focused executable built and all 18 tests passed. Raw logs are copied byte-for-byte and their hashes plus final source/binary hashes are in `checks.json`.

Commands from this worktree root:

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_server_lane_addon_sampling.exe
(cd test && ../_build/default/test/test_server_lane_addon_sampling.exe test 'host boundary' 15)
(cd test && ../_build/default/test/test_server_lane_addon_sampling.exe)
```

Only loopback fixture providers were invoked. No full repository suite, release validation, live provider dispatch, or TerminalBench was run. Request and terminal-outcome persistence remain mandatory. This proof is this candidate’s focused behavior, not production readiness.
