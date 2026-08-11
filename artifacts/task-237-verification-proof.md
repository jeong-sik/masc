# task-237 verification proof

This proof closes the three contract evidence paths at the producer worktree:
`lib/dune`, `bin/main_eio.ml`, and
`lib/server/server_dashboard_http_keeper_api_post.ml`.

## Contract evidence

- `artifact:lib/dune`: the root `masc` library now explicitly declares
  `keeper_github_identity` in
  `(modules (:standard keeper_github_identity))` immediately below the
  `library` stanza. `:standard` preserves the other inferred modules while
  making this module inclusion visible in the contract source. The successful
  build generated
  `_build-task237-explicit/default/lib/masc.ml-gen:483-484`:
  `module Keeper_github_identity = Masc__Keeper_github_identity`.
- `artifact:bin/main_eio.ml`: line 23 aliases
  `Masc.Keeper_github_identity`; the `keeper-github` subcommands at lines
  1205, 1211, and 1217 call `run_cli_login`, `run_cli_status`, and
  `run_cli_logout`.
- `artifact:lib/server/server_dashboard_http_keeper_api_post.ml`: line 44
  defines `handle_keeper_github_login_post`, which calls `login_env`,
  `login_argv`, `secure_config_files`, and `observe`; the companion
  `.mli` exports the same handler and the umbrella API interface exposes it
  to the dashboard route.

## Verification

From this worktree, both exact commands exited 0:

```
dune build --root . --build-dir _build-task237-explicit lib/masc.cmxa bin/main_eio.exe
dune exec --root . --build-dir _build-task237-explicit test/keeper_github_identity/test_keeper_github_identity.exe
```

The focused executable reported `Test Successful`, 8 tests run.
`git diff --check` also exited 0.

## Changes on top of PR #28215

- `lib/dune`: explicitly include `keeper_github_identity` in the
  `masc` library module set.
- `lib/keeper_runtime/keeper_event_queue_persistence.ml`: pass both state
  arguments to `stable_read_only_observation`.
- `lib/server/server_dashboard_http_keeper_api_post.ml`: use the already
  redacted stderr value in failed-login detail.
- Commits before this evidence repair: `be42abe5ac`, `2f04f495bf`,
  `4c862acec5`; the explicit Dune declaration is the final integration
  repair in this resubmission.
