# Browser startup and compound read admission

Baseline #41185 `7192f1fa3f1c843d57b9a8121263117d0aec5753`. Three current comments reproduced independently:

- Surface compound read: fake automation changes activity to Off while answering Tabs. The original read rejects its Page phase; the repaired opaque read admission retains its selected target and permits only closed Tabs/Page/Capture commands. Final tests cover automation and Stagehand, plus the existing two-client live fixture now turns Off between hops. Every new read after Off remains refused without dispatch.
- Stagehand executor capture fixture: original capture fails Unobserved before exercising the fake executor. Scoped Enabled observation is installed and withdrawn together with its executor using cleanup.
- Both server startups: the same production prepared-worker path has per-invocation cleanup held by promises, real Runtime configuration is replaced, and cleanup is released. Original deferred reads launch the newly saved fake WebDriver executable or install the newly saved Stagehand backend. Capturing the immutable Runtime configuration before preparing/forking the worker makes both regressions pass. Production keeps its original Fiber.fork and exception propagation; only the test adapter returns a fork_promise. No mutable global seam or duplicate startup implementation.

Focused command (worktree root):

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_server_browser_stagehand.exe test/test_browser_surface.exe test/test_browser_stagehand_executor.exe test/test_browser_activity.exe
```

Executables ran from `test/` using `../_build/default/test/<name>.exe`. Meaningful RED selectors were browser Surface `behavior 0`, Stagehand executor `capture 0`, and server startup `lifetime 0-1`. Final results: Surface15, Stagehand executor13, activity15, server lifetime6: **49 distinct tests passed**. The first three suites precede the final startup-only cleanup simplification/EINTR correction; their Browser source/dependency closure did not change. Final focused build covers all four consumers.

Two setup compile errors (wrong Masc.Runtime namespace and missing direct browser_lane library) and the initial empty Runtime fixture rejection are preserved but excluded from behavior RED. The legacy orphan-group fixture then failed twice on Unix.waitpid EINTR at an unchanged line. Its correction retries only EINTR on the exact leader wait, retaining orphan/reaping/profile assertions; the final full six-case server lifetime suite passes. These failures are fixture interruption, not a product startup regression. No failed log was overwritten.

All seventeen raw logs are copied byte-for-byte, including blank EOF lines; checks.json pins final source, binary and log hashes. This is focused native/fixture proof, not a real browser session, provider run, release/full CI or TerminalBench result. Backend connection/deadline/idle guards and ordinary per-command activity rechecks remain intact.
