# task-237 verification proof

This proof is intentionally short so the reviewer can inspect the integration without relying on truncated source snapshots.

## Public surfaces

`bin/main_eio.ml:23` aliases `Masc.Keeper_github_identity`; lines 1200-1217 pass
`Keeper_github_identity.run_cli_login`, `run_cli_status`, and `run_cli_logout`
to the `keeper-github` CLI command.

`lib/server/server_dashboard_http_keeper_api_post.ml:44` defines
`handle_keeper_github_login_post`. Its login flow calls
`Keeper_github_identity.login_env`, `login_argv`, `secure_config_files`,
and `observe` (lines 61-132).

`lib/dune:1` uses `(include_subdirs unqualified)` for the library source tree.
The module is proven linkable through the successful `lib/masc.cmxa` and
`bin/main_eio.exe` builds below; the CLI alias and server handler both compile
against the exported module.

## Focused verification

From this worktree, exact commands exited 0:

```
dune build --root . --build-dir _build-task237 lib/masc.cmxa bin/main_eio.exe
dune exec --root . --build-dir _build-task237 test/keeper_github_identity/test_keeper_github_identity.exe
```

The focused test reported: `Test Successful`, 8 tests run.

## Changes on top of PR #28215

- `lib/keeper_runtime/keeper_event_queue_persistence.ml` now passes both
  `first` and `second` to `stable_read_only_observation`.
- `lib/server/server_dashboard_http_keeper_api_post.ml` uses the already-redacted
  `stderr` value when building the failed-login detail.
- Commits: `be42abe5ac`, `2f04f495bf`.
