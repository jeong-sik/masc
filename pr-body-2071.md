## Why

`test_dashboard_http_core` reports failures when its binary is run directly instead of through dune. Both are harness artifacts, not product defects — they created task-2060 and task-2061.

Running `_build/default/test/test_dashboard_http_core.exe` from the repo root on `origin/main` `6a9b9ac462`:

```
12 failures! in 1.414s. 144 tests run.
```

- **10 failures** (`context-window shrink guard` 5·6·7·10·13·16·18·20·21, `dashboard behavior contracts` 23): `test/dune`'s `(env ...)` block sets `MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false`, but a direct run does not inherit it, so the sandbox preflight defaults on and every config POST answers `docker_preflight_failed` in a Docker-less sandbox.
- **1 failure** (`dashboard behavior contracts` 14): the shared fixture is opened as `../dashboard/src/api/fixtures/scheduled-automation-lookup-found.json`, relative to the working directory; from the repo root that path does not exist.
- The 12th is `executor_pool` 37, the same preflight artifact.

## What changed

`test/test_dashboard_http_core.ml` only:

- At startup, pin `MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false` unless the caller already set it — the same value the dune stanza uses, so dune runs are unchanged.
- Resolve the shared fixture against the checkout root: `DUNE_SOURCEROOT` under dune, otherwise the nearest `dune-project` above the working directory.

No assertion was weakened or deleted, and `test/dune`'s `(env ...)` isolation is untouched.

## Verification (this head)

Head `e3f94ceb53` (base `origin/main` `6a9b9ac462`).

```
$ dune build test/test_dashboard_http_core.exe
build_exit=0

$ env -u MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED _build/default/test/test_dashboard_http_core.exe   # cwd = repo root
exit=0  -> Test Successful in 4.076s. 144 tests run.

$ env -u MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED ../_build/default/test/test_dashboard_http_core.exe  # cwd = test/
exit=0  -> Test Successful in 4.084s. 144 tests run.

$ dune exec test/test_dashboard_http_core.exe
dune_exec_exit=0  -> Test Successful in 4.173s. 144 tests run.
```

Before the change the direct repo-root run was `12 failures! ... 144 tests run.` (exit 1).

## Scope

Test harness only. No product code, no timeout widened.

— indie-geek-blue
