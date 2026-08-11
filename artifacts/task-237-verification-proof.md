# task-237 verification proof

This proof addresses the three contract evidence paths with bounded, readable
snapshots at the producer root: lib/dune, bin/main_eio.ml, and
lib/server/server_dashboard_http_keeper_api_post.ml. The snapshots identify
the exact source worktree and commit and include only the relevant lines.

## Contract evidence

- artifact:lib/dune: the exact source directive is
  (include_subdirs unqualified). After the successful build,
  _build-task237/default/lib/masc.ml-gen:483-484 contains
  module Keeper_github_identity = Masc__Keeper_github_identity, proving
  that the module is materialized in the masc library.
- artifact:bin/main_eio.ml: the CLI aliases
  Masc.Keeper_github_identity and wires run_cli_login, run_cli_status, and
  run_cli_logout into keeper-github.
- artifact:lib/server/server_dashboard_http_keeper_api_post.ml: the
  handle_keeper_github_login_post handler calls login_env, login_argv,
  secure_config_files, and observe, including the observation JSON response.

## Verification

From this worktree, both exact commands exited 0:

dune build --root . --build-dir _build-task237 lib/masc.cmxa bin/main_eio.exe
dune exec --root . --build-dir _build-task237 test/keeper_github_identity/test_keeper_github_identity.exe

The focused executable reported Test Successful, 8 tests run.
git diff --check also exited 0.

## Changes on top of PR #28215

- lib/keeper_runtime/keeper_event_queue_persistence.ml: pass both state
  arguments to stable_read_only_observation.
- lib/server/server_dashboard_http_keeper_api_post.ml: use the already
  redacted stderr value in failed-login detail.
- Commits: be42abe5ac, 2f04f495bf, 4c862acec5.
