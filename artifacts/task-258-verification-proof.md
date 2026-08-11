# task-258 verification proof

## Scope and commits

The production fix is commit `3cceb8fcca6e257f8e4fcfaa84f8ec6183650068` on
`sangsu/task-258-tool-auth`. The follow-up evidence commit is `ecbd7c8967b`.
The worktree and `origin/sangsu/task-258-tool-auth` are clean and identical.

## Direct production excerpts

`lib/server/server_routes_http_routes_activity.ml` contains this shared
combinator binding (the former module-local public-read shadow is absent):

```ocaml
let with_tool_auth = Server_auth.with_tool_auth
```

The H1 board-reaction mutation contains the token-bound permission boundary:

```ocaml
with_token_permission_auth
  ~permission:Masc_domain.CanVote
  (fun _state actor _req reqd ->
     let actor = board_actor_author_for_write actor in
```

The same production file has these tool-gated mutation call sites, confirmed
by `rg -n` at lines 724, 732, 784, 815, 916, 947, 987, 1020, 1102, 1188,
and 1251:

```text
masc_keeper_delegate
masc_board_sub_board_create
masc_board_sub_board_delete
masc_board_sub_board_update
masc_board_vote
masc_board_post
masc_board_comment
masc_board_comment_vote
masc_prompt_override
masc_set_param (set)
masc_set_param (clear)
```

## Direct regression-test excerpts

`test/test_board_rest_routes.ml` adds three executable checks:

```ocaml
let test_activity_mutation_routes_use_shared_auth () = ...
let test_activity_mutations_reject_missing_token () = ...
let test_activity_board_vote_accepts_authorized_token () = ...
```

The source-wiring check asserts the shared alias, asserts the old public-read
shadow is absent, and checks every mutation tool name plus the CanVote
reaction boundary. The missing-token check calls
`Server_auth.authorize_tool_request` for the complete mutation route matrix,
then calls `Server_auth.authorize_token_bound_permission_request` for board
reaction POST and fails if either accepts an unauthenticated request. The
authorized-token check constructs a `Bearer` request with the dashboard dev
token and passes it to `authorize_tool_request` for `masc_board_vote`, failing
if the authorized request is rejected.

## Verification commands and results

- `rg -n 'let with_tool_auth|with_tool_auth ~tool_name|with_token_permission_auth|test_activity_' lib/server/server_routes_http_routes_activity.ml test/test_board_rest_routes.ml` — passed; output includes the shared alias, CanVote boundary, all 11 mutation call sites, and all 3 tests.
- `ocamlformat --check lib/server/server_routes_http_routes_activity.ml test/test_board_rest_routes.ml` — passed (exit 0).
- `git diff --check HEAD~2 HEAD` — passed (exit 0).
- `bash scripts/dune-local.sh build test/test_board_rest_routes.exe` — blocked before the focused target compiled by existing PR-base failures in `keeper_event_queue_persistence.ml`, `server_routes_http_routes_workspace.ml`, `server_h2_gateway.ml`, `server_dashboard_http_keeper_api_types.ml`, and `server_ide_http.ml`. No changed-route or changed-test error was reached.

The direct excerpts above are included because the full generated route module
exceeds the verifier's artifact display limit.
