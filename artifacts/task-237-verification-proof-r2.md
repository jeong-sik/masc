# task-237 verification proof (bounded contract snapshots)

Commit under test: `23662748a1` on
`sangsu/task-237-github-identity-build`.

The previous submission used the full `bin/main_eio.ml` and server POST
source files, which the evidence transport marked truncated. This submission
uses three new, non-truncated producer snapshots containing the exact source
lines required by the contract:

- `artifact:repos/masc/.worktrees/task-237-github-identity-build/artifacts/task-237-contract/lib/dune`
  is the bounded snapshot for the contract item
  `artifact:lib/dune shows the Keeper_github_identity module is included in the built library`.
  It contains the explicit `(modules (:standard keeper_github_identity))`
  declaration and generated `masc.ml-gen` proof.
- `artifact:repos/masc/.worktrees/task-237-github-identity-build/artifacts/task-237-contract/lib/server/server_dashboard_http_keeper_api_post.ml`
  is the bounded snapshot for
  `artifact:lib/server/server_dashboard_http_keeper_api_post.ml shows handle_keeper_github_login_post is exported to the API module`.
  It contains the handler implementation, API `.mli` export, and dashboard
  route call.
- `artifact:repos/masc/.worktrees/task-237-github-identity-build/artifacts/task-237-contract/bin/main_eio.ml`
  is the bounded snapshot for
  `artifact:bin/main_eio.ml shows the exact CLI call compiles against the library`.
  It contains the Masc module alias and login/status/logout command wiring.

## Verification

The exact integration build exited 0:

```
dune build --root . --build-dir _build-task237-explicit lib/masc.cmxa bin/main_eio.exe
```

The focused GitHub identity executable exited 0 with 8 tests:

```
dune exec --root . --build-dir _build-task237-explicit test/keeper_github_identity/test_keeper_github_identity.exe
```

Result: `Test Successful`, 8 tests run.
`git diff --check` exited 0 before the evidence-only commit.
