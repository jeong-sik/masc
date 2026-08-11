# task-258 bounded auth evidence

This bounded extract is the review-sized evidence for the changes in
`lib/server/server_routes_http_routes_activity.ml`; it avoids requiring the
reviewer to inspect the full generated route module.

## Production route wiring

The module-local public-read shadow was removed:

```ocaml
let with_tool_auth = Server_auth.with_tool_auth
```

The mutation call sites retained in the module are:

- `masc_keeper_delegate`
- `masc_board_sub_board_create`
- `masc_board_sub_board_delete`
- `masc_board_sub_board_update`
- `masc_board_vote`
- `masc_board_post`
- `masc_board_comment`
- `masc_board_comment_vote`
- `masc_prompt_override`
- `masc_set_param` (set and clear)

The H1 board-reaction mutation is token-bound and permission-gated:

```ocaml
with_token_permission_auth
  ~permission:Masc_domain.CanVote
```

The board-reaction GET projection remains public-read.

## Regression coverage

`test/test_board_rest_routes.ml` contains these checks:

- `test_activity_mutation_routes_use_shared_auth`: asserts the shared auth
  alias, every mutation tool callsite, and the CanVote reaction boundary.
- `test_activity_mutations_reject_missing_token`: checks the missing-token
  rejection matrix for all mutation families and board-reaction POST.
- `test_activity_board_vote_accepts_authorized_token`: checks that a valid
  dashboard token reaches the board-vote authorization boundary.

## Verification status

- `ocamlformat --check lib/server/server_routes_http_routes_activity.ml test/test_board_rest_routes.ml`: passed.
- `git diff --check`: passed.
- `bash scripts/dune-local.sh build test/test_board_rest_routes.exe`: could not reach the focused target because the PR-base has pre-existing compile/warning-as-error failures in `keeper_event_queue_persistence.ml`, `server_routes_http_routes_workspace.ml`, `server_h2_gateway.ml`, `server_dashboard_http_keeper_api_types.ml`, and `server_ide_http.ml`.
